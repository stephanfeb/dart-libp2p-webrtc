import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart' as rtc;
import 'rtc_runtime.dart';

/// A libdatachannel data channel.
///
/// Messages are received in polling mode: no message callback is installed,
/// so libdatachannel queues them and signals "available"; [messages] is fed
/// by draining that queue with `rtcReceiveMessage`.
class RtcDataChannel {
  /// [send] waits once this much data is queued natively...
  static const highWaterMark = 1024 * 1024;

  /// ...until it drains below this.
  static const lowWaterMark = 256 * 1024;

  final int id;
  final void Function(RtcDataChannel)? _onDisposed;

  final _messages = StreamController<Uint8List>();
  final _opened = Completer<void>();
  final _closed = Completer<void>();
  Completer<void>? _drained;
  bool _disposed = false;

  RtcDataChannel.attach(this.id, {void Function(RtcDataChannel)? onDisposed})
      : _onDisposed = onDisposed {
    RtcRuntime.instance.registerChannel(
      id,
      ChannelCallbacks(
        onOpen: _onOpen,
        onClosed: _onClosed,
        onError: dispose,
        onAvailable: _onAvailable,
        onBufferedAmountLow: _onBufferedAmountLow,
      ),
    );
    check('rtcSetBufferedAmountLowThreshold',
        rtc.rtcSetBufferedAmountLowThreshold(id, lowWaterMark));
    // Inbound channels can already be open, and have messages queued, before
    // their callbacks were installed.
    if (rtc.rtcIsOpen(id)) _onOpen();
    _onAvailable();
  }

  /// Completes when the channel is open; errors if it closes first.
  Future<void> get opened => _opened.future;

  /// Completes when the channel has closed.
  Future<void> get done => _closed.future;

  bool get isOpen => !_disposed && rtc.rtcIsOpen(id);

  /// Binary messages, in order. Closes when the channel closes.
  Stream<Uint8List> get messages => _messages.stream;

  String get label => readNativeString((buf, size) => rtc.rtcGetDataChannelLabel(id, buf, size));

  /// SCTP stream id.
  int get streamId => check('rtcGetDataChannelStream', rtc.rtcGetDataChannelStream(id));

  int get maxMessageSize => check('rtcMaxMessageSize', rtc.rtcMaxMessageSize(id));

  int get bufferedAmount => check('rtcGetBufferedAmount', rtc.rtcGetBufferedAmount(id));

  /// Sends one binary message, waiting first if too much is already queued.
  Future<void> send(Uint8List data) async {
    while (bufferedAmount > highWaterMark) {
      final drained = _drained ??= Completer<void>();
      await drained.future;
    }
    if (_disposed) throw StateError('Data channel $id is closed');
    using((arena) {
      final buf = arena<Uint8>(data.length);
      buf.asTypedList(data.length).setAll(0, data);
      check('rtcSendMessage', rtc.rtcSendMessage(id, buf.cast(), data.length));
    });
  }

  /// Closes the channel; [done] completes once it has closed.
  Future<void> close() async {
    if (_disposed) return;
    rtc.rtcClose(id);
    await done;
  }

  /// Releases the native channel without waiting for the remote side, e.g.
  /// when the peer connection is closing.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    RtcRuntime.instance.unregisterChannel(id);
    rtc.rtcDelete(id);
    if (!_opened.isCompleted) {
      _opened.completeError(StateError('Data channel $id closed before opening'));
      _opened.future.ignore();
    }
    if (!_closed.isCompleted) _closed.complete();
    _drained?.complete();
    _drained = null;
    _messages.close();
    _onDisposed?.call(this);
  }

  void _onOpen() {
    if (!_opened.isCompleted) _opened.complete();
  }

  void _onClosed() {
    _onAvailable(); // deliver anything still queued
    dispose();
  }

  void _onAvailable() {
    if (_disposed) return;
    _ReceiveBuffer.drain(id, _messages.add);
  }

  void _onBufferedAmountLow() {
    _drained?.complete();
    _drained = null;
  }
}

/// One receive buffer shared by all channels; it grows to the largest message.
abstract final class _ReceiveBuffer {
  static int _capacity = 64 * 1024;
  static Pointer<Uint8> _buffer = malloc<Uint8>(_capacity);
  static final Pointer<Int> _size = malloc<Int>();

  static void drain(int id, void Function(Uint8List) onMessage) {
    while (true) {
      _size.value = _capacity;
      final result = rtc.rtcReceiveMessage(id, _buffer.cast(), _size);
      if (result == rtc.RTC_ERR_NOT_AVAIL) return;
      if (result == rtc.RTC_ERR_TOO_SMALL) {
        malloc.free(_buffer);
        _capacity = _size.value.abs();
        _buffer = malloc<Uint8>(_capacity);
        continue;
      }
      // A closed or deleted channel has nothing more to deliver.
      if (result < 0) return;
      // Negative sizes mark text messages, NUL terminator included.
      final size = _size.value;
      final length = size >= 0 ? size : -size - 1;
      onMessage(Uint8List.fromList(_buffer.asTypedList(length)));
    }
  }
}
