import 'dart:async';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';
import 'package:dart_libp2p/p2p/protocol/multistream/client.dart' as multistream;
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:dart_libp2p/p2p/transport/transport.dart';
import 'package:dart_libp2p/p2p/transport/transport_config.dart';
import 'package:logging/logging.dart';

import '../ffi/rtc_peer_connection.dart';
import 'signaling.dart';
import 'webrtc_conn.dart';

final _log = Logger('WebRtcTransport');

/// The libp2p `/webrtc` (private-to-private) transport: peers that share a
/// relay exchange SDP over a `/webrtc-signaling/0.0.1` stream on their
/// relayed connection, then talk directly over WebRTC.
///
/// Add it to the host before the circuit relay transport (which is added at
/// start), [attach] it to the host, and listen on `/webrtc` to accept
/// connections:
///
/// ```dart
/// final webrtc = WebRtcTransport();
/// final host = await Libp2p.new_([
///   Libp2p.transport(webrtc),
///   Libp2p.transport(TCPTransport(...)),
///   Libp2p.listenAddrs([MultiAddr('/webrtc'), ...]),
///   Libp2p.relay(true),
/// ]);
/// webrtc.attach(host);
/// await host.start();
/// ```
///
/// With an AutoRelay reservation the host then advertises
/// `<relay>/p2p-circuit/webrtc`. A dial needs a relayed connection to the
/// peer first; [upgrade] moves a relayed peer onto WebRTC.
class WebRtcTransport implements Transport {
  final RtcConfig rtcConfig;

  /// Limit on the SDP exchange and ICE.
  final Duration signalingTimeout;

  @override
  final TransportConfig config;

  Host? _host;
  _WebRtcListener? _listener;

  WebRtcTransport({
    this.rtcConfig = const RtcConfig(),
    this.signalingTimeout = const Duration(seconds: 30),
    this.config = TransportConfig.defaultConfig,
  });

  /// Gives the transport the host whose relayed connections carry its
  /// signaling. Call before the host starts listening.
  void attach(Host host) {
    _host = host;
    if (_listener != null) host.setStreamHandler(signalingProtocol, _answer);
  }

  Host get _attached => _host ?? (throw StateError('WebRtcTransport is not attached to a host'));

  @override
  List<String> get protocols => const ['/p2p-circuit/webrtc'];

  /// `.../p2p-circuit/webrtc[/p2p/<peer>]`.
  @override
  bool canDial(MultiAddr addr) {
    final names = addr.components.map((c) => c.$1.name).toList();
    final circuit = names.lastIndexOf(Protocols.circuit.name);
    return circuit >= 0 && circuit + 1 < names.length && names[circuit + 1] == Protocols.webrtc.name;
  }

  /// Only the bare `/webrtc`.
  @override
  bool canListen(MultiAddr addr) => addr.components.length == 1 && addr.hasProtocol(Protocols.webrtc.name);

  @override
  Future<Conn> dial(MultiAddr addr, {Duration? timeout, bool simultaneousConnect = false}) async {
    final peerIdStr = addr.components.lastWhere((c) => c.$1.code == Protocols.p2p.code, orElse: () {
      throw ArgumentError('$addr does not name the peer to dial');
    }).$2;
    final peer = PeerId.fromString(peerIdStr);
    final relayed = _attached.network
        .connsToPeer(peer)
        .where((c) => !c.isClosed && c.remoteMultiaddr.hasProtocol(Protocols.circuit.name))
        .lastOrNull;
    if (relayed == null) {
      throw StateError('no relayed connection to $peer to signal WebRTC over');
    }

    final limit = timeout != null && timeout < signalingTimeout ? timeout : signalingTimeout;
    final stream = await relayed.newStream(Context());
    try {
      await stream.setProtocol(await multistream.selectOneOf([signalingProtocol], stream));
    } catch (_) {
      await stream.reset();
      rethrow;
    }
    _log.fine('signaling WebRTC to $peer over ${relayed.remoteMultiaddr}');
    return initiateWebRtc(stream, config: rtcConfig, timeout: limit);
  }

  /// Opens a WebRTC connection to [peer], which must be connected through a
  /// relay. It joins the host's connections, so new streams to [peer] prefer
  /// it over the relayed one.
  Future<Conn> upgrade(PeerId peer) async {
    final host = _attached;
    final relayed = host.network
        .connsToPeer(peer)
        .where((c) => !c.isClosed && c.remoteMultiaddr.hasProtocol(Protocols.circuit.name))
        .lastOrNull;
    if (relayed == null) throw StateError('no relayed connection to $peer');
    // The swarm dials from the peerstore: give it this relay's /webrtc
    // address, then dial past the relayed connection (as DCUtR does).
    final viaRelay = relayed.remoteMultiaddr.decapsulate(Protocols.circuit.name)!;
    await host.peerStore.addrBook.addAddrs(
      peer,
      [MultiAddr('$viaRelay/p2p-circuit/webrtc')],
      AddressTTL.tempAddrTTL,
    );
    return host.network.dialPeer(Context().withForceDirectDial('webrtc upgrade'), peer);
  }

  Future<void> _answer(P2PStream stream, PeerId peer) async {
    final listener = _listener;
    if (listener == null || listener.isClosed) {
      await stream.reset();
      return;
    }
    try {
      listener._add(await answerWebRtc(stream, config: rtcConfig, timeout: signalingTimeout));
    } catch (e) {
      _log.fine('inbound WebRTC from $peer failed: $e');
    }
  }

  @override
  Future<Listener> listen(MultiAddr addr) async {
    if (!canListen(addr)) throw ArgumentError('WebRtcTransport listens on /webrtc only, not $addr');
    if (_listener != null && !_listener!.isClosed) throw StateError('already listening on /webrtc');
    final listener = _listener = _WebRtcListener(addr, onClose: () => _host?.removeStreamHandler(signalingProtocol));
    _host?.setStreamHandler(signalingProtocol, _answer);
    return listener;
  }

  @override
  Future<void> dispose() async => _listener?.close();
}

class _WebRtcListener implements Listener {
  @override
  final MultiAddr addr;
  final void Function() _onClose;
  final _conns = StreamController<TransportConn>();
  late final _queue = StreamIterator(_conns.stream);
  var _closed = false;

  _WebRtcListener(this.addr, {required void Function() onClose}) : _onClose = onClose;

  void _add(WebRtcConn conn) {
    if (_closed) {
      unawaited(conn.close());
    } else {
      _conns.add(conn);
    }
  }

  @override
  Future<TransportConn?> accept() async => await _queue.moveNext() ? _queue.current : null;

  @override
  Stream<TransportConn> get connectionStream => _conns.stream;

  @override
  bool get isClosed => _closed;

  @override
  bool supportsAddr(MultiAddr addr) => addr.components.length == 1 && addr.hasProtocol('webrtc');

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _onClose();
    // Not awaited: a controller's close only completes once listened to.
    unawaited(_conns.close());
  }
}
