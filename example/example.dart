// Two dart-libp2p hosts meet through a circuit relay and move onto a direct
// WebRTC connection. A js-libp2p browser does the same with
// `<relay>/p2p-circuit/webrtc/p2p/<listener>`.
//
//   dart run example/example.dart /ip4/<relay-ip>/tcp/<port>/p2p/<relay-id>
import 'dart:convert';
import 'dart:io';

import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p_webrtc/libp2p.dart';

const _hello = '/example/hello/1.0.0';

/// A host with the WebRTC transport, listening on `/webrtc`, and TCP to
/// reach the relay. The WebRTC transport goes first: the swarm uses the
/// first transport that can dial an address.
Future<(Host, WebRtcTransport)> _host() async {
  final connManager = ConnectionManager();
  final webrtc = WebRtcTransport(
    rtcConfig: const RtcConfig(iceServers: ['stun:stun.l.google.com:19302']),
  );
  final host = await Libp2p.new_([
    Libp2p.connManager(connManager),
    Libp2p.transport(webrtc),
    Libp2p.transport(TCPTransport(connManager: connManager)),
    Libp2p.listenAddrs([MultiAddr('/webrtc')]),
    Libp2p.relay(true),
  ]);
  webrtc.attach(host); // before start: the signaling handler needs the host
  await host.start();
  return (host, webrtc);
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/example.dart <relay multiaddr with /p2p/<id>>');
    exit(64);
  }
  final relay = AddrInfo.fromMultiaddr(MultiAddr(args.first));

  // The listener books a slot on the relay so peers can reach it there.
  final (listener, _) = await _host();
  listener.setStreamHandler(_hello, (stream, peer) async {
    await stream.write(utf8.encode('hello from ${listener.id} over ${stream.conn.remoteMultiaddr}'));
    await stream.close();
  });
  await listener.connect(relay);
  await (listener as BasicHost).circuitV2Client!.reserve(relay.id);

  // The dialer reaches it through the relay (which it must be connected to,
  // or at least know the address of), then upgrades to WebRTC.
  final (dialer, webrtc) = await _host();
  await dialer.connect(relay);
  await dialer.connect(AddrInfo(listener.id, [MultiAddr('${args.first}/p2p-circuit')]));
  final conn = await webrtc.upgrade(listener.id);
  print('direct connection: ${conn.remoteMultiaddr}');

  // New streams prefer the direct connection.
  final stream = await dialer.newStream(listener.id, [_hello], Context());
  print(utf8.decode(await stream.read()));

  await dialer.close();
  await listener.close();
}
