// Two dart-libp2p hosts with the WebRTC transport, connected through a
// circuit relay (Dart, or go-libp2p with its default limits): one upgrades
// the relayed connection to WebRTC, and the hosts' swarms carry the
// protocols over it.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/network/swarm/swarm_conn.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p_webrtc/interop.dart';
import 'package:dart_libp2p_webrtc/libp2p.dart';
import 'package:test/test.dart';

import '../turn_server.dart';

const _echo = '/test/echo/1.0.0';

Future<Uint8List> _readAll(P2PStream stream) async {
  final out = BytesBuilder(copy: false);
  while (true) {
    final chunk = await stream.read();
    if (chunk.isEmpty) return out.takeBytes();
    out.add(chunk);
  }
}

Uint8List _random(int length, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => r.nextInt(256)));
}

Future<Uint8List> _echoOver(Host host, PeerId peer, Uint8List data) async {
  final stream = await host.newStream(peer, [_echo], Context());
  final reply = _readAll(stream);
  await stream.write(data);
  await stream.closeWrite();
  return reply;
}

void main() {
  group('through a Dart relay', () => _suite('dart'));
  final noGo = _hasGo() ? false : 'needs Go to build interop/go/relay';
  group('through a go relay', () => _suite('go'), skip: noGo);
  // Both transports relay-only, so WebRTC itself runs through TURN.
  group('through a go relay, WebRTC over TURN', () => _suite('go', turn: true), skip: noGo, tags: ['turn']);
}

bool _hasGo() {
  try {
    return Process.runSync('go', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void _suite(String relayKind, {bool turn = false}) {
  String? turnSkip;
  final cleanup = <Future<void> Function()>[];
  late PeerId relayId;
  late String relayTcp;
  late Host a;
  late Host b;
  late WebRtcTransport aWebRtc;

  Future<(Host, WebRtcTransport)> peer() async {
    final connManager = ConnectionManager();
    final webrtc = WebRtcTransport(
      rtcConfig: turn ? RtcConfig(iceServers: [turnUrl], relayOnly: true) : const RtcConfig(),
    );
    final host = await Libp2p.new_([
      Libp2p.connManager(connManager),
      Libp2p.transport(webrtc),
      Libp2p.transport(TCPTransport(connManager: connManager)),
      Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/tcp/0'), MultiAddr('/webrtc')]),
      Libp2p.relay(true),
    ]);
    webrtc.attach(host);
    await host.start();
    cleanup.add(host.close);
    host.setStreamHandler(_echo, (stream, _) async {
      await stream.write(await _readAll(stream));
      await stream.closeWrite();
    });
    await host.connect(AddrInfo.fromMultiaddr(MultiAddr(relayTcp)));
    return (host, webrtc);
  }

  setUpAll(() async {
    if (turn) turnSkip = await turnUnavailable();
    if (relayKind == 'dart') return;
    final unavailable = await ExternalRelay.unavailable(relayKind);
    if (unavailable != null) fail(unavailable);
  });

  setUp(() async {
    if (turnSkip != null) return;
    if (relayKind == 'dart') {
      final connManager = ConnectionManager();
      final relay = await Libp2p.new_([
        Libp2p.connManager(connManager),
        Libp2p.transport(TCPTransport(connManager: connManager)),
        Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/tcp/0')]),
        Libp2p.relay(true),
        Libp2p.forceReachability(Reachability.public),
      ]);
      await relay.start();
      cleanup.add(relay.close);
      relayId = relay.id;
      relayTcp = '${relay.network.listenAddresses.firstWhere((a) => a.hasProtocol('tcp'))}/p2p/${relay.id}';
    } else {
      final relay = await ExternalRelay.start(relayKind);
      cleanup.add(relay.close);
      relayId = relay.peerId;
      relayTcp = relay.tcp;
    }

    (a, aWebRtc) = await peer();
    (b, _) = await peer();
    // The relay starts its hop service once it sees itself as public.
    await _eventually(() => (b as BasicHost).circuitV2Client!.reserve(relayId));
    await a.connect(AddrInfo(b.id, [MultiAddr('$relayTcp/p2p-circuit')]));
  });

  tearDown(() async {
    for (final close in cleanup.reversed) {
      await close();
    }
    cleanup.clear();
  });

  bool skipped() {
    if (turnSkip == null) return false;
    markTestSkipped(turnSkip!);
    return true;
  }

  List<Type> connTypes(Host host, PeerId peer) => [
        for (final c in host.network.connsToPeer(peer)) (c as SwarmConn).conn.runtimeType,
      ];

  test('upgrade moves a relayed peer onto WebRTC, in both swarms', () async {
    if (skipped()) return;
    // The go relay limits relayed connections (2 min, 128 KiB) and says so
    // in HOP STATUS and STOP CONNECT; the Dart relay applies no such limit.
    final limited = relayKind == 'go';
    final relayed = a.network.connsToPeer(b.id).single;
    expect(relayed.remoteMultiaddr.hasProtocol('p2p-circuit'), isTrue);
    expect(relayed.stat.stats.limited, limited);
    await _eventually(() async => expect(b.network.connsToPeer(a.id).single.stat.stats.limited, limited));

    final conn = await aWebRtc.upgrade(b.id);
    expect((conn as SwarmConn).conn, isA<WebRtcConn>());
    expect(conn.remoteMultiaddr.toString(), matches(RegExp(r'^/ip[46]/.+/udp/\d+/webrtc$')));
    expect(conn.state.streamMultiplexer, webRtcMuxerProtocol);
    final pair = (conn.conn as WebRtcConn).selectedCandidatePair!;
    if (turn) {
      expect(pair.local, contains('typ relay'));
      expect(pair.remote, contains('typ relay'));
    } else {
      expect(pair.local, isNot(contains('typ relay')));
    }
    expect(connTypes(a, b.id), contains(WebRtcConn));
    await _eventually(() async => expect(connTypes(b, a.id), contains(WebRtcConn)));
  });

  test('host streams prefer the WebRTC connection, both ways', () async {
    if (skipped()) return;
    await aWebRtc.upgrade(b.id);
    await _eventually(() async => expect(connTypes(b, a.id), contains(WebRtcConn)));

    final ab = await a.newStream(b.id, [_echo], Context());
    expect(ab.conn.remoteMultiaddr.hasProtocol('webrtc'), isTrue);
    await ab.reset();
    final ba = await b.newStream(a.id, [_echo], Context());
    expect(ba.conn.remoteMultiaddr.hasProtocol('webrtc'), isTrue);
    await ba.reset();

    final data = _random(300 * 1024, 1);
    expect(await _echoOver(a, b.id, data), data);
    expect(await _echoOver(b, a.id, data), data);
  });

  test('16 concurrent streams and ping', () async {
    if (skipped()) return;
    await aWebRtc.upgrade(b.id);
    final replies = await Future.wait([
      for (var i = 0; i < 16; i++) _echoOver(a, b.id, _random(4096, i)),
    ]);
    for (var i = 0; i < 16; i++) {
      expect(replies[i], _random(4096, i));
    }
    final rtt = await PingService(a).ping(b.id).first;
    expect(rtt.error, isNull);
  });

  test('a dial with no relayed connection fails', () async {
    if (skipped()) return;
    await a.network.closePeer(b.id);
    expect(() => aWebRtc.upgrade(b.id), throwsStateError);
  });
}

/// Retries [body] for up to [timeout].
Future<T> _eventually<T>(Future<T> Function() body, {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      return await body();
    } catch (_) {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
