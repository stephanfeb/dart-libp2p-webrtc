// A dart-libp2p host with the WebRTC transport, and the checks one such host
// runs against a peer it reaches through a relay: shared by the phone app
// (lib/src/interop/libp2p_phone.dart) and the desktop hub
// (lib/src/interop/libp2p_hub.dart).
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/network/swarm/swarm_conn.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';

import '../ffi/rtc_peer_connection.dart';
import '../libp2p/webrtc_conn.dart';
import '../libp2p/webrtc_transport.dart';

/// The echo protocol the browser page (interop/browser/libp2p-page.js) and
/// the Dart hosts serve: reply with everything read, then close.
const echoProtocol = '/test/echo/1.0.0';

/// A started host: TCP and UDX for dialing the relay, WebRTC listening on `/webrtc`,
/// the circuit relay client, and [echoProtocol]. It does not listen on TCP,
/// so peers (on the same LAN too) reach it only through the relay, and an
/// upgrade can only end on WebRTC.
/// [identity] fixes the peer id (a new one by default).
Future<(Host, WebRtcTransport)> createTestHost({RtcConfig rtcConfig = const RtcConfig(), KeyPair? identity}) async {
  final connManager = ConnectionManager();
  final webrtc = WebRtcTransport(rtcConfig: rtcConfig);
  final host = await Libp2p.new_([
    if (identity != null) Libp2p.identity(identity),
    Libp2p.connManager(connManager),
    Libp2p.transport(webrtc),
    Libp2p.transport(TCPTransport(connManager: connManager)),
    Libp2p.transport(UDXTransport(connManager: connManager)),
    Libp2p.listenAddrs([MultiAddr('/webrtc')]),
    Libp2p.relay(true),
  ]);
  webrtc.attach(host);
  await host.start();
  host.setStreamHandler(echoProtocol, (stream, _) async {
    await stream.write(await _readAll(stream));
    await stream.closeWrite();
  });
  return (host, webrtc);
}

/// Connects [host] to the relay at [relayAddr] (with `/p2p/<id>`) and books
/// a reservation, so peers can reach it at `<relayAddr>/p2p-circuit`.
Future<void> reserveOn(Host host, String relayAddr) async {
  final info = AddrInfo.fromMultiaddr(MultiAddr(relayAddr));
  await host.connect(info);
  await (host as BasicHost).circuitV2Client!.reserve(info.id);
}

/// One check's outcome.
class CheckResult {
  final String name;
  final bool ok;
  final String detail;
  final Duration elapsed;

  CheckResult(this.name, this.ok, this.detail, this.elapsed);

  Map<String, Object> toJson() => {'name': name, 'ok': ok, 'detail': detail, 'ms': elapsed.inMilliseconds};

  factory CheckResult.fromJson(Map<String, dynamic> json) => CheckResult(json['name'] as String,
      json['ok'] as bool, json['detail'] as String, Duration(milliseconds: json['ms'] as int));

  @override
  String toString() => '${ok ? 'ok  ' : 'FAIL'} $name (${elapsed.inMilliseconds} ms): $detail';
}

/// Dials [peer] over WebRTC from [host], signaling through the relay at
/// [relayAddr], and exercises the connection: ping, echoes, concurrent
/// streams. Stops at the first failed step that later ones need.
///
/// With [fresh] it first closes every connection to [peer] and connects
/// through the relay again; without, it upgrades the relayed connection
/// that already exists (and keeps streams on it, e.g. the one that asked
/// for this dial, open).
Future<List<CheckResult>> runWebRtcChecks(
  Host host,
  WebRtcTransport webrtc,
  PeerId peer,
  String relayAddr, {
  bool fresh = true,
  void Function(CheckResult result)? onResult,
}) async {
  final results = <CheckResult>[];
  Future<bool> check(String name, Future<String> Function() body, {Duration timeout = const Duration(seconds: 45)}) async {
    final watch = Stopwatch()..start();
    CheckResult result;
    try {
      result = CheckResult(name, true, await body().timeout(timeout), watch.elapsed);
    } catch (e) {
      result = CheckResult(name, false, '$e', watch.elapsed);
    }
    results.add(result);
    onResult?.call(result);
    return result.ok;
  }

  if (!await check('relayed', () async {
    if (fresh) await host.network.closePeer(peer);
    await host.connect(AddrInfo(peer, [MultiAddr('$relayAddr/p2p-circuit')]));
    final conns = host.network.connsToPeer(peer);
    if (!conns.any((c) => c.remoteMultiaddr.hasProtocol('p2p-circuit'))) {
      throw StateError('not relayed: ${conns.map((c) => c.remoteMultiaddr).join(', ')}');
    }
    return 'connected through $relayAddr';
  })) {
    return results;
  }
  if (!await check('webrtc', () async {
    final conn = await webrtc.upgrade(peer) as SwarmConn;
    final pair = (conn.conn as WebRtcConn).selectedCandidatePair;
    String type(String? candidate) => RegExp(r'typ (\w+)').firstMatch(candidate ?? '')?.group(1) ?? '?';
    return '${conn.remoteMultiaddr}, path ${type(pair?.local)} → ${type(pair?.remote)}';
  })) {
    return results;
  }
  await check('ping', () async {
    final rtt = await PingService(host).ping(peer).first;
    if (rtt.error != null) throw rtt.error!;
    return '${rtt.rtt?.inMilliseconds} ms';
  });
  await check('echo 1 KiB', () async {
    final data = _pattern(1024, 1);
    _expectEqual(await _echo(host, peer, data), data);
    return 'over ${await _pathOf(host, peer)}';
  });
  await check('echo 1 MiB', () async {
    final data = _pattern(1024 * 1024, 2);
    final watch = Stopwatch()..start();
    _expectEqual(await _echo(host, peer, data), data);
    final kibPerSec = 2 * 1024 * 1000 ~/ max(1, watch.elapsedMilliseconds);
    return '$kibPerSec KiB/s round trip';
  }, timeout: const Duration(seconds: 90));
  await check('16 streams', () async {
    final replies = await Future.wait([for (var i = 0; i < 16; i++) _echo(host, peer, _pattern(4096, 10 + i))]);
    for (var i = 0; i < 16; i++) {
      _expectEqual(replies[i], _pattern(4096, 10 + i));
    }
    return '16 × 4 KiB';
  });
  return results;
}

Future<String> _pathOf(Host host, PeerId peer) async {
  final stream = await host.newStream(peer, [echoProtocol], Context());
  final addr = stream.conn.remoteMultiaddr;
  await stream.reset();
  if (!addr.hasProtocol('webrtc')) throw StateError('streams go over $addr, not WebRTC');
  return '$addr';
}

Future<Uint8List> _echo(Host host, PeerId peer, Uint8List data) async {
  final stream = await host.newStream(peer, [echoProtocol], Context());
  final reply = _readAll(stream);
  await stream.write(data);
  await stream.closeWrite();
  return reply;
}

Future<Uint8List> _readAll(P2PStream stream) async {
  final out = BytesBuilder(copy: false);
  while (true) {
    final chunk = await stream.read();
    if (chunk.isEmpty) return out.takeBytes();
    out.add(chunk);
  }
}

Uint8List _pattern(int length, int seed) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 255));

void _expectEqual(Uint8List actual, Uint8List expected) {
  if (actual.length != expected.length) {
    throw StateError('echoed ${actual.length} bytes, sent ${expected.length}');
  }
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) throw StateError('echo differs at byte $i');
  }
}
