// Desktop hub for the phone libp2p tests (example/interop_app, "libp2p").
// Run from the repository root.
//
// On the LAN: a go-libp2p relay, a Dart host and a headless browser that
// dial each registering phone over /webrtc; phones use http://<ip>:8788.
//
//   dart run tool/libp2p_hub.dart [--browser chrome|firefox|webkit|none] [--stun]
//
// Anywhere: the Dart host and the browser reserve on a public relay, and
// phones start sessions over libp2p through it with the printed multiaddr.
// STUN is on. Without a browser, leave out --relay-browser and pass
// --browser none.
//
//   dart run tool/libp2p_hub.dart --relay /ip4/…/udp/…/udx/p2p/<relay> \
//     --relay-browser /dns4/…/tcp/…/wss/p2p/<relay>
//
// The LAN mode needs Go, and Node 22+ with interop/browser installed for
// the browser.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart';
import 'package:dart_libp2p_webrtc/interop.dart';

const _stunServers = ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478'];

Future<void> main(List<String> arguments) async {
  final args = (ArgParser()
        ..addOption('port', defaultsTo: '8788')
        ..addOption('browser', defaultsTo: 'chrome')
        ..addOption('relay', help: 'public relay for the Dart host and phones (sessions over libp2p)')
        ..addOption('relay-browser', help: "the public relay's WebSocket address, for the browser")
        ..addMultiOption('turn', help: 'turn:user:pass@host:port, added to the ICE servers')
        ..addFlag('stun', help: "STUN for the hub's Dart host (always on with --relay)"))
      .parse(arguments);
  final relay = args['relay'] as String?;
  final iceServers = [
    if (relay != null || args['stun'] as bool) ..._stunServers,
    ...args['turn'] as List<String>,
  ];

  final browser = args['browser'] as String;
  final hub = await Libp2pHub.start(
    port: int.parse(args['port'] as String),
    browser: browser == 'none' ? null : browser,
    relay: relay,
    relayBrowser: args['relay-browser'] as String?,
    rtcConfig: RtcConfig(iceServers: iceServers),
    identity: await generateEd25519KeyPairFromSeed(_seed()),
  );
  print('ICE servers: $iceServers');
  if (relay == null) {
    print('phones: http://${hub.relayForPhones.split('/')[2]}:${hub.port}  or  ${hub.dialBackAddress}');
  } else {
    print('phones: ${hub.dialBackAddress}');
  }
  print('(Ctrl-C to stop)');
  // Reservations last an hour; book again well before that.
  final refresh = Timer.periodic(const Duration(minutes: 20), (_) {
    hub.refreshReservation().catchError((Object e) => print('reservation refresh failed: $e'));
  });
  await ProcessSignal.sigint.watch().first;
  refresh.cancel();
  await hub.close();
  exit(0);
}

/// A persistent identity seed (build/hub_identity.seed), so the multiaddr
/// phones are built with stays valid across hub restarts.
Uint8List _seed() {
  final file = File('build/hub_identity.seed');
  if (!file.existsSync()) {
    final random = Random.secure();
    file
      ..createSync(recursive: true)
      ..writeAsBytesSync([for (var i = 0; i < 32; i++) random.nextInt(256)]);
  }
  return file.readAsBytesSync();
}
