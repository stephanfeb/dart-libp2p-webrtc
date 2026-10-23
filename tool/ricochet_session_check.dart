// One session against a public relay from this machine: the hub (Dart host,
// headless browser) and the phone code in one process. A check of the relay
// setup before using phones.
//
//   dart run tool/ricochet_session_check.dart <relay for Dart/phones> <relay WebSocket address>
import 'dart:io';

import 'package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart';
import 'package:dart_libp2p_webrtc/interop.dart';

const _stun = ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478'];

Future<void> main(List<String> args) async {
  final hub = await Libp2pHub.start(
    port: 0,
    relay: args[0],
    relayBrowser: args[1],
    rtcConfig: const RtcConfig(iceServers: _stun),
  );
  final report = await runPhoneSession(hub.dialBackAddress,
      label: 'desktop', rtcConfig: const RtcConfig(iceServers: _stun));
  print(report);
  await hub.close();
  exit(report.error == null && report.all.every((r) => r.ok) ? 0 : 1);
}
