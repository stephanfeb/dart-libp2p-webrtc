// A js-libp2p node in a real browser and a dart-libp2p host with the
// WebRtcTransport connect over libp2p `/webrtc`, each dialing the other:
// browser → relay (WebSockets) → Dart host (TCP) for the relayed
// connection, /webrtc-signaling/0.0.1 over it, then the direct WebRTC
// connection carries identify, ping and an echo protocol. Runs through a
// js-libp2p relay and a go-libp2p relay (whose default limits make the
// relayed connections limited, as on go-ricochet).
//
// Setup: (cd interop/browser && npm install). Needs Node 22+ (set NODE to
// its binary if `node` is older), Go for the go relay, and
// BROWSER=chrome|chromium|firefox|webkit.
@Tags(['browser'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart';
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
import 'package:dart_libp2p_webrtc/interop.dart';
import 'package:dart_libp2p_webrtc/libp2p.dart';
import 'package:test/test.dart';

import '../turn_server.dart';
import 'relays.dart';

final _dir = Directory('interop/browser');
const _echo = '/test/echo/1.0.0';

Future<Uint8List> _readAll(P2PStream stream) async {
  final out = BytesBuilder(copy: false);
  while (true) {
    final chunk = await stream.read();
    if (chunk.isEmpty) return out.takeBytes();
    out.add(chunk);
  }
}

void main() {
  for (final relayKind in const ['js', 'go']) {
    group('through the $relayKind relay', () => _suite(relayKind));
  }
  // The browser may only use TURN relay candidates; the Dart host has the
  // TURN server too, as a fallback, and no restriction.
  group('through the go relay, browser on TURN only', () => _suite('go', turn: true),
      tags: ['turn'],
      skip: Platform.environment['BROWSER'] == 'firefox' ? 'Firefox will not use a TURN server on loopback' : false);
}

void _suite(String relayKind, {bool turn = false}) {
  final cleanup = <Future<void> Function()>[];
  final results = <String, Map<String, dynamic>>{};
  final finished = Completer<void>();
  late Host dart;
  // The Dart swarm's WebRTC connections when the browser reported its dial.
  // (Their selected candidate pairs: the browser closes them before the
  // tests look.)
  var pairsAtDial = <({String local, String remote})?>[];
  late WebRtcTransport webrtc;
  late String relayTcp;
  String? skip;

  setUpAll(() async {
    // The browser driver needs what the js relay needs.
    skip = await ExternalRelay.unavailable('js') ??
        await ExternalRelay.unavailable(relayKind) ??
        (turn ? await turnUnavailable() : null);
    if (skip != null) return;

    final build = await Process.run('npm', ['run', 'build'], workingDirectory: _dir.path);
    if (build.exitCode != 0) fail('bundling the browser page failed:\n${build.stderr}');

    // The relay: TCP for us, WebSockets for the browser.
    final relay = await ExternalRelay.start(relayKind);
    cleanup.add(relay.close);
    final relayId = relay.peerId;
    relayTcp = relay.tcp;
    final relayWs = relay.ws;

    // The Dart host: answers /webrtc-signaling over the relayed connection,
    // and its swarm serves its protocols over the WebRTC connections.
    final connManager = ConnectionManager();
    webrtc = WebRtcTransport(rtcConfig: RtcConfig(iceServers: [if (turn) turnUrl]));
    dart = await Libp2p.new_([
      Libp2p.connManager(connManager),
      Libp2p.transport(webrtc),
      Libp2p.transport(TCPTransport(connManager: connManager)),
      Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/tcp/0'), MultiAddr('/webrtc')]),
      Libp2p.relay(true),
    ]);
    webrtc.attach(dart);
    await dart.start();
    cleanup.add(dart.close);
    dart.setStreamHandler(_echo, (stream, peer) async {
      await stream.write(await _readAll(stream));
      await stream.closeWrite();
    });
    await dart.connect(AddrInfo.fromMultiaddr(MultiAddr(relayTcp)));
    await (dart as BasicHost).circuitV2Client!.reserve(relayId);
    final target = '$relayWs/p2p-circuit/webrtc/p2p/${dart.id}';
    print('Dart host reachable at $target');

    // Serve the bundled page; the browser reports results as console lines.
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    cleanup.add(() => http.close(force: true));
    http.listen((request) async {
      if (request.uri.path == '/bundle.js') {
        request.response.headers.contentType = ContentType('text', 'javascript', charset: 'utf-8');
        await request.response.addStream(File('${_dir.path}/build/libp2p-page.bundle.js').openRead());
      } else {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<!doctype html><script type="module" src="/bundle.js"></script>');
      }
      await request.response.close();
    });

    final driver = await BrowserDriver.start(
      driverDir: _dir,
      browser: Platform.environment['BROWSER'] ?? 'chrome',
      onLog: (line) {
        final i = line.indexOf('RESULT ');
        if (i < 0) {
          print('  $line');
          return;
        }
        final result = jsonDecode(line.substring(i + 'RESULT '.length)) as Map<String, dynamic>;
        print('  ${result['ok'] == true ? 'ok  ' : 'FAIL'} ${result['name']}: ${result['detail']}');
        results[result['name'] as String] = result;
        if (result['name'] == 'dial') {
          pairsAtDial = [
            for (final c in dart.network.conns)
              if ((c as SwarmConn).conn case final WebRtcConn conn) conn.selectedCandidatePair,
          ];

        }
        if ((result['name'] == 'listening' || result['name'] == 'fatal') && !finished.isCompleted) {
          finished.complete();
        }
      },
    );
    cleanup.add(driver.close);
    print('browser: ${driver.description}');
    driver.open(Uri.parse('http://127.0.0.1:${http.port}/').replace(queryParameters: {
      'target': target,
      'relay': relayWs,
      if (turn) ...turnForBrowser(),
    }));
    await finished.future.timeout(const Duration(seconds: 90), onTimeout: () {});
  });

  tearDownAll(() async {
    for (final close in cleanup.reversed) {
      await close();
    }
  });

  /// Without TURN the path is direct; with it (the browser relay-only), the
  /// remote is the browser's relay candidate.
  void expectPath(({String local, String remote})? pair) {
    expect(pair, isNotNull);
    expect(pair!.remote, turn ? contains('typ relay') : isNot(contains('typ relay')), reason: '$pair');
  }

  void expectResult(String name) {
    if (skip != null) {
      markTestSkipped(skip!);
      return;
    }
    expect(results['fatal'], isNull, reason: '${results['fatal']?['detail']}');
    final result = results[name];
    expect(result, isNotNull, reason: 'the browser never reported "$name"');
    expect(result!['ok'], isTrue, reason: '${result['detail']}');
  }

  test('browser dials the Dart host over /p2p-circuit/webrtc', () {
    expectResult('dial');
    if (skip != null) return;
    expect(pairsAtDial, hasLength(1), reason: 'WebRTC connections in the Dart swarm');
    expectPath(pairsAtDial.single);
  });

  test('the browser reports its ICE path', () {
    expectResult('path');
    if (skip != null) return;
    final path = jsonDecode(results['path']!['detail'] as String) as Map<String, dynamic>;
    // A relay-only browser sends through TURN only. Its local candidate can
    // show as prflx: the relay reaches the Dart host through Docker
    // Desktop's NAT, which maps it to another address. (The Dart side sees
    // the browser's relay candidate; see expectPath.)
    expect(path['local'], turn ? isIn(['relay', 'prflx']) : isNot('relay'), reason: '$path');
  });

  test("browser pings the Dart host's ping service", () => expectResult('ping'));
  test('echo over a negotiated stream', () => expectResult('echo-small'));
  test('1 MiB echo', () => expectResult('echo-1mib'));
  test('16 concurrent echo streams', () => expectResult('echo-16-streams'));
  test("identify learns the Dart host's protocols", () => expectResult('identify'));

  test('the Dart host dials the browser over /p2p-circuit/webrtc', () async {
    expectResult('listening');
    if (skip != null) return;
    final browser = PeerId.fromString(results['listening']!['detail'] as String);
    // Start from a fresh relayed connection: the browser closed its WebRTC
    // connection, which Chrome only signals by letting ICE time out.
    await dart.network.closePeer(browser);
    await dart.connect(AddrInfo(browser, [MultiAddr('$relayTcp/p2p-circuit')]));
    // The go relay's default limits make the relayed connection limited (the
    // js relay here applies none); signaling must work on it all the same.
    expect(dart.network.connsToPeer(browser).single.stat.stats.limited, relayKind == 'go');

    final conn = await webrtc.upgrade(browser);
    expect((conn as SwarmConn).conn, isA<WebRtcConn>());
    expectPath((conn.conn as WebRtcConn).selectedCandidatePair);

    final data = Uint8List.fromList(List.generate(1024 * 1024, (i) => (i * 31 + 5) & 255));
    final stream = await dart.newStream(browser, [_echo], Context());
    expect(stream.conn.remoteMultiaddr.hasProtocol('webrtc'), isTrue);
    final reply = _readAll(stream);
    await stream.write(data);
    await stream.closeWrite();
    expect(await reply, data);

    final rtt = await PingService(dart).ping(browser).first;
    expect(rtt.error, isNull);
  });
}
