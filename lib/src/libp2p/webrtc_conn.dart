import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/mux.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/protocol/protocol.dart';
import 'package:dart_libp2p/core/protocol/switch.dart';
import 'package:dart_libp2p/p2p/protocol/multistream/client.dart' as multistream;
import 'package:dart_libp2p/p2p/protocol/multistream/multistream.dart';
import 'package:logging/logging.dart';

import '../ffi/rtc_data_channel.dart';
import '../ffi/rtc_peer_connection.dart';
import 'webrtc_stream.dart';

final _log = Logger('WebRtcConn');

/// js-libp2p reports this as the connection's muxer.
const webRtcMuxerProtocol = '/webrtc';

/// Label of the data channel the offerer opens so its SDP has an
/// application section; it is closed once connected (spec: webrtc.md).
const initChannelLabel = 'init';

/// A libp2p connection over an established WebRTC peer connection. Streams
/// are data channels, so it is secure (DTLS, bound to the peer IDs by the
/// authenticated signaling) and multiplexed without an upgrade: the swarm
/// adopts it as an [UpgradedTransportConn].
class WebRtcConn implements UpgradedTransportConn {
  final RtcPeerConnection _pc;
  @override
  final String id;
  @override
  final PeerId localPeer;
  @override
  final PeerId remotePeer;
  final PublicKey? _remotePublicKey;
  @override
  final MultiAddr localMultiaddr;
  @override
  final MultiAddr remoteMultiaddr;
  final Direction direction;
  final DateTime _opened = DateTime.now();

  final _accepted = StreamController<WebRtcStream>();
  late final _acceptQueue = StreamIterator(_accepted.stream);
  final _streams = <WebRtcStream>{};
  late final StreamSubscription<RtcDataChannel> _channelSub;
  late final StreamSubscription<RtcPeerState> _stateSub;
  final _closed = Completer<void>();

  static int _nextId = 0;

  WebRtcConn({
    required RtcPeerConnection peerConnection,
    required this.localPeer,
    required this.remotePeer,
    PublicKey? remotePublicKey,
    required this.localMultiaddr,
    required this.remoteMultiaddr,
    required this.direction,
  })  : _pc = peerConnection,
        _remotePublicKey = remotePublicKey,
        id = 'webrtc-${_nextId++}' {
    _channelSub = _pc.onDataChannel.listen((channel) {
      if (channel.label == initChannelLabel) {
        // Only used during establishment; the offerer closes it.
        return;
      }
      _accepted.add(_track(WebRtcStream(channel, this, Direction.inbound)));
    });
    _stateSub = _pc.onStateChange.listen((state) {
      if (state == RtcPeerState.failed || state == RtcPeerState.closed) {
        _log.fine('$id: peer connection ${state.name}');
        unawaited(close());
      }
    });
  }

  /// Completes when the connection has closed.
  Future<void> get done => _closed.future;

  /// `ip:port` of the selected remote ICE candidate.
  String? get remoteAddress => _pc.remoteAddress;

  /// The selected ICE candidate pair; `typ relay` means TURN carries it.
  ({String local, String remote})? get selectedCandidatePair => _pc.selectedCandidatePair;

  WebRtcStream _track(WebRtcStream stream) {
    _streams.add(stream);
    return stream;
  }

  @override
  Future<MuxedStream> openStream(Context context) async {
    if (isClosed) throw StateError('$id: connection closed');
    // Spec: stream channels have an empty label and are negotiated in-band.
    final channel = _pc.createDataChannel('');
    await channel.opened.timeout(const Duration(seconds: 10));
    return _track(WebRtcStream(channel, this, Direction.outbound));
  }

  @override
  Future<MuxedStream> acceptStream() async {
    if (!await _acceptQueue.moveNext()) throw StateError('$id: connection closed');
    return _acceptQueue.current;
  }

  @override
  Future<P2PStream> newStream(Context context) async => await openStream(context) as WebRtcStream;

  @override
  Future<List<P2PStream>> get streams async => [
        for (final s in _streams)
          if (!s.isClosed) s,
      ];

  @override
  bool get isClosed => _closed.isCompleted;

  @override
  Future<void> close() async {
    if (_closed.isCompleted) return;
    _closed.complete();
    await _channelSub.cancel();
    await _stateSub.cancel();
    for (final stream in _streams.toList()) {
      await stream.reset();
    }
    await _pc.close();
    // Not awaited: a controller's close only completes once listened to.
    unawaited(_accepted.close());
  }

  @override
  Future<PublicKey?> get remotePublicKey async => _remotePublicKey;

  @override
  ConnState get state => const ConnState(
        streamMultiplexer: webRtcMuxerProtocol,
        security: '',
        transport: 'webrtc',
        usedEarlyMuxerNegotiation: false,
      );

  @override
  ConnStats get stat => _WebRtcConnStats(
        Stats(direction: direction, opened: _opened),
        _streams.where((s) => !s.isClosed).length,
      );

  @override
  ConnScope get scope => NullScope();

  // --- TransportConn: there is no byte stream under the data channels ---

  @override
  Future<Uint8List> read([int? length]) => throw UnsupportedError('WebRtcConn has no raw byte stream');

  @override
  Future<void> write(Uint8List data) => throw UnsupportedError('WebRtcConn has no raw byte stream');

  @override
  Socket get socket => throw UnsupportedError('WebRtcConn has no socket');

  @override
  void setReadTimeout(Duration timeout) {}

  @override
  void setWriteTimeout(Duration timeout) {}

  @override
  void notifyActivity() {}

  // --- Use without a swarm ---

  /// Answers inbound streams with [mux]'s protocol handlers (e.g. a host's
  /// `mux`), as the swarm does for its connections.
  Future<void> serveStreams(ProtocolSwitch mux) async {
    while (!isClosed) {
      final WebRtcStream stream;
      try {
        stream = await acceptStream() as WebRtcStream;
      } on StateError {
        return;
      }
      unawaited(_handleStream(mux, stream));
    }
  }

  Future<void> _handleStream(ProtocolSwitch mux, WebRtcStream stream) async {
    try {
      final (protocol, handler) = await mux.negotiate(stream);
      // Bytes read past the negotiation belong to the protocol.
      if (mux is MultistreamMuxer) {
        final leftover = mux.drainLeftover(stream.id());
        if (leftover != null) stream.pushData(leftover);
      }
      await stream.setProtocol(protocol);
      handler(protocol, stream);
    } catch (e) {
      _log.fine('$id: inbound stream ${stream.id()} failed negotiation: $e');
      await stream.reset();
    }
  }

  /// Opens a stream and selects the first of [protocols] the remote speaks.
  Future<WebRtcStream> newProtocolStream(List<ProtocolID> protocols) async {
    final stream = await newStream(Context()) as WebRtcStream;
    try {
      final protocol = await multistream.selectOneOf(protocols, stream);
      await stream.setProtocol(protocol);
      return stream;
    } catch (_) {
      await stream.reset();
      rethrow;
    }
  }

  @override
  String toString() => 'WebRtcConn($id, ${direction.name}, $remotePeer)';
}

class _WebRtcConnStats extends ConnStats {
  const _WebRtcConnStats(Stats stats, int numStreams) : super(stats: stats, numStreams: numStreams);
}
