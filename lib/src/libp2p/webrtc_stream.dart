import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/mux.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:logging/logging.dart';

import '../ffi/rtc_data_channel.dart';
import 'pb.dart';

final _log = Logger('WebRtcStream');

/// How long [WebRtcStream.closeWrite] waits for the remote's FIN_ACK
/// (js-libp2p uses the same).
const finAckTimeout = Duration(seconds: 10);

/// A libp2p stream over one data channel, with the libp2p WebRTC message
/// framing (spec: webrtc/README.md#multiplexing) providing half-close and
/// reset, which data channels lack.
class WebRtcStream implements P2PStream<Uint8List>, MuxedStream, PushbackStream {
  final RtcDataChannel _channel;
  final Conn _conn;
  final Direction direction;
  final String _id;
  final DateTime _opened = DateTime.now();
  String _protocol = '';

  final _decoder = LengthPrefixedDecoder();
  final _readQueue = <Uint8List>[];
  Completer<void>? _readable;
  Future<void> _writeChain = Future.value();
  final _finAck = Completer<void>();

  bool _remoteFin = false;
  bool _remoteStoppedReading = false;
  bool _localReadClosed = false;
  bool _localWriteClosed = false;
  bool _channelClosed = false;
  ResetException? _reset;
  DateTime? _readDeadline;
  DateTime? _writeDeadline;

  WebRtcStream(this._channel, this._conn, this.direction) : _id = '${_channel.streamId}' {
    _finAck.future.ignore();
    _channel.messages.listen(_onChunk, onDone: _onChannelClosed);
  }

  // --- Reading ---

  @override
  Future<Uint8List> read([int? maxLength]) async {
    while (true) {
      if (_reset != null) throw _reset!;
      if (_readQueue.isNotEmpty) return _take(maxLength);
      if (_remoteFin || _localReadClosed || _channelClosed) return Uint8List(0);
      final readable = _readable ??= Completer<void>();
      final deadline = _readDeadline;
      if (deadline == null) {
        await readable.future;
      } else {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) throw TimeoutException('read deadline exceeded');
        await readable.future.timeout(remaining, onTimeout: () {
          throw TimeoutException('read deadline exceeded');
        });
      }
    }
  }

  /// Puts [bytes] back at the front of the read queue, e.g. bytes that
  /// multistream-select read past the end of its negotiation.
  @override
  void pushData(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _readQueue.insert(0, bytes);
    _wakeReaders();
  }

  /// Up to [maxLength] queued bytes, joining chunks so exact-length readers
  /// see whole messages that arrived in several frames.
  Uint8List _take(int? maxLength) {
    if (maxLength == null) {
      final builder = BytesBuilder(copy: false);
      _readQueue.forEach(builder.add);
      final all = builder.takeBytes();
      _readQueue.clear();
      return all;
    }
    final out = BytesBuilder(copy: false);
    while (_readQueue.isNotEmpty && out.length < maxLength) {
      final chunk = _readQueue.first;
      final wanted = maxLength - out.length;
      if (chunk.length <= wanted) {
        out.add(_readQueue.removeAt(0));
      } else {
        out.add(Uint8List.sublistView(chunk, 0, wanted));
        _readQueue[0] = Uint8List.sublistView(chunk, wanted);
      }
    }
    return out.takeBytes();
  }

  void _onChunk(Uint8List chunk) {
    final List<Uint8List> frames;
    try {
      frames = _decoder.add(chunk);
    } on FormatException catch (e) {
      _log.warning('stream $_id: bad frame ($e), resetting');
      unawaited(reset());
      return;
    }
    for (final bytes in frames) {
      final frame = StreamFrame.decode(bytes);
      final message = frame.message;
      if (message != null && message.isNotEmpty && !_localReadClosed && !_remoteFin) {
        _readQueue.add(message);
      }
      switch (frame.flag) {
        case FrameFlag.fin:
          _remoteFin = true;
          _sendFlag(FrameFlag.finAck);
        case FrameFlag.stopSending:
          _remoteStoppedReading = true;
        case FrameFlag.resetStream:
          _reset ??= const ResetException('stream reset by remote');
          if (!_finAck.isCompleted) _finAck.completeError(_reset!);
          _closeChannel();
        case FrameFlag.finAck:
          if (!_finAck.isCompleted) _finAck.complete();
        case null:
          break;
      }
    }
    _wakeReaders();
    _closeChannelIfDone();
  }

  void _onChannelClosed() {
    _channelClosed = true;
    if (!_finAck.isCompleted) _finAck.complete(); // nothing more can arrive
    _wakeReaders();
  }

  void _wakeReaders() {
    final readable = _readable;
    _readable = null;
    readable?.complete();
  }

  // --- Writing ---

  @override
  Future<void> write(List<int> data) {
    // Chained so concurrent writers' frames don't interleave.
    final result = _writeChain.then((_) => _write(data));
    _writeChain = result.catchError((_) {});
    return result;
  }

  Future<void> _write(List<int> data) async {
    if (_reset != null) throw _reset!;
    if (_localWriteClosed) throw StateError('stream $_id: write after closeWrite');
    if (_remoteStoppedReading) throw StateError('stream $_id: remote stopped reading');
    if (_channelClosed) throw StateError('stream $_id: channel closed');
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final send = () async {
      for (var offset = 0; offset < bytes.length; offset += maxFramePayload) {
        final end = offset + maxFramePayload < bytes.length ? offset + maxFramePayload : bytes.length;
        await _channel.send(StreamFrame(message: Uint8List.sublistView(bytes, offset, end)).encodeWithLength());
      }
    }();
    final deadline = _writeDeadline;
    if (deadline == null) return send;
    return send.timeout(deadline.difference(DateTime.now()), onTimeout: () {
      throw TimeoutException('write deadline exceeded');
    });
  }

  void _sendFlag(FrameFlag flag) {
    if (_channelClosed || !_channel.isOpen) return;
    _channel.send(StreamFrame(flag: flag).encodeWithLength()).catchError((Object e) {
      _log.fine('stream $_id: could not send ${flag.name}: $e');
    });
  }

  // --- Closing ---

  /// Sends FIN and waits (bounded) for the remote's FIN_ACK, so data sent
  /// before it is known to have arrived.
  @override
  Future<void> closeWrite() async {
    if (_localWriteClosed || _reset != null) return;
    await _writeChain; // FIN goes after queued data
    _localWriteClosed = true;
    _sendFlag(FrameFlag.fin);
    try {
      await _finAck.future.timeout(finAckTimeout);
    } on TimeoutException {
      _log.fine('stream $_id: no FIN_ACK within ${finAckTimeout.inSeconds} s');
    } on ResetException {
      // reset while closing; nothing left to wait for
    }
    _closeChannelIfDone();
  }

  /// Sends STOP_SENDING; further data from the remote is discarded.
  @override
  Future<void> closeRead() async {
    if (_localReadClosed || _reset != null) return;
    _localReadClosed = true;
    _readQueue.clear();
    _sendFlag(FrameFlag.stopSending);
    _wakeReaders();
    _closeChannelIfDone();
  }

  @override
  Future<void> close() async {
    await closeWrite();
    await closeRead();
    _closeChannel();
  }

  @override
  Future<void> reset() async {
    if (_reset != null) return;
    _reset = const ResetException('stream reset');
    _sendFlag(FrameFlag.resetStream);
    _readQueue.clear();
    if (!_finAck.isCompleted) _finAck.completeError(_reset!);
    _wakeReaders();
    _closeChannel();
  }

  /// Spec: once our FIN is acknowledged and the remote has finished sending
  /// (or we stopped reading), the data channel can go.
  void _closeChannelIfDone() {
    final writeDone = _localWriteClosed && (_finAck.isCompleted || _channelClosed);
    final readDone = _remoteFin || _localReadClosed;
    if (writeDone && readDone) _closeChannel();
  }

  void _closeChannel() {
    if (_channelClosed) return;
    _channelClosed = true;
    unawaited(_channel.close().catchError((Object _) {}));
    _wakeReaders();
  }

  // --- Metadata ---

  @override
  String id() => _id;

  @override
  String protocol() => _protocol;

  @override
  Future<void> setProtocol(String id) async => _protocol = id;

  @override
  StreamStats stat() => StreamStats(direction: direction, opened: _opened);

  @override
  Conn get conn => _conn;

  @override
  StreamManagementScope scope() => NullScope();

  @override
  P2PStream<Uint8List> get incoming => this;

  @override
  bool get isClosed => _channelClosed || _reset != null;

  @override
  bool get isWritable => !_localWriteClosed && !_remoteStoppedReading && !isClosed;

  @override
  Future<void> setDeadline(DateTime? time) async {
    _readDeadline = time;
    _writeDeadline = time;
  }

  @override
  Future<void> setReadDeadline(DateTime time) async => _readDeadline = time;

  @override
  Future<void> setWriteDeadline(DateTime time) async => _writeDeadline = time;

  @override
  String toString() => 'WebRtcStream($_id, ${direction.name}, $_protocol)';
}
