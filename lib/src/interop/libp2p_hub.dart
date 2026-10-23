// The desktop side of the phone libp2p tests (tool/libp2p_hub.dart): a
// relay the phones reserve on (a local go relay, or a public one), a Dart
// host and a js-libp2p browser that each dial a phone over /webrtc, and two
// ways for the phone app (lib/src/interop/libp2p_phone.dart) to start a
// session:
//
// HTTP, on the LAN:
//   GET  /config          relay address for phones, the hub's peer ids
//   POST /phone           {peer, label} → {run}: starts the hub's dials
//   GET  /status?run=…    hub results so far; hubDone, browserPeer
//   POST /report          {run, label, results}: the phone's own results
//
// libp2p, from anywhere the relay is reachable: dialBackProtocol and
// reportProtocol on the hub's Dart host (see libp2p_dialback.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';

import '../ffi/rtc_peer_connection.dart';
import '../libp2p/webrtc_transport.dart';
import 'browser_driver.dart';
import 'external_relay.dart';
import 'libp2p_checks.dart';
import 'libp2p_dialback.dart';

class Libp2pHub {
  final HttpServer _server;
  final ExternalRelay? _ownRelay;

  /// The relay as the hub's Dart host dials it.
  final String _relayDart;

  /// The relay as the browser dials it (WebSockets).
  final String _relayBrowser;

  /// The relay as phones dial it.
  final String relayForPhones;
  final Host _host;
  final WebRtcTransport _webrtc;
  final BrowserDriver? _browser;
  final HttpServer _pages;
  final void Function(String line) _log;
  final _sessions = <String, _Session>{};
  var _nextRun = 0;

  Libp2pHub._(this._server, this._ownRelay, this._relayDart, this._relayBrowser, this.relayForPhones, this._host,
      this._webrtc, this._browser, this._pages, this._log) {
    _server.listen(_handle);
    _host.setStreamHandler(dialBackProtocol, _dialBack);
    _host.setStreamHandler(reportProtocol, _reportOverLibp2p);
  }

  /// Run from the repository root. [browser] is chrome, chromium, firefox,
  /// webkit, or null for no browser.
  ///
  /// Without [relay] the hub starts a go relay on the LAN. With it (a
  /// public relay's address for Dart hosts and phones, e.g. over UDX),
  /// [relayBrowser] is that relay's WebSocket address for the browser.
  static Future<Libp2pHub> start({
    int port = 8788,
    String? browser = 'chrome',
    String? relay,
    String? relayBrowser,
    int relayTcpPort = 4001,
    int relayWsPort = 4002,
    RtcConfig rtcConfig = const RtcConfig(),
    KeyPair? identity,
    void Function(String line) log = print,
  }) async {
    if (relay != null && browser != null && relayBrowser == null) {
      throw ArgumentError('a browser needs relayBrowser, the relay\'s WebSocket address');
    }
    final missing = (relay == null ? await ExternalRelay.unavailable('go') : null) ??
        (browser == null ? null : await ExternalRelay.unavailable('js'));
    if (missing != null) throw StateError(missing);

    final ownRelay = relay == null
        ? await ExternalRelay.start('go', args: ['-ip', '0.0.0.0', '-tcp', '$relayTcpPort', '-ws', '$relayWsPort'])
        : null;
    final relayDart = relay ?? ownRelay!.tcp;
    final (host, webrtc) = await createTestHost(rtcConfig: rtcConfig, identity: identity);
    await reserveOn(host, relayDart);

    // The browser page, served on loopback.
    final pages = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    BrowserDriver? driver;
    late final Libp2pHub hub;
    if (browser != null) {
      final dir = Directory('interop/browser');
      final build = await Process.run('npm', ['run', 'build'], workingDirectory: dir.path);
      if (build.exitCode != 0) throw StateError('bundling the browser page failed:\n${build.stderr}');
      pages.listen((request) async {
        if (request.uri.path == '/bundle.js') {
          request.response.headers.contentType = ContentType('text', 'javascript', charset: 'utf-8');
          await request.response.addStream(File('${dir.path}/build/libp2p-page.bundle.js').openRead());
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write('<!doctype html><script type="module" src="/bundle.js"></script>');
        }
        await request.response.close();
      });
      driver = await BrowserDriver.start(driverDir: dir, browser: browser, onLog: (line) => hub._browserLog(line));
    }

    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    hub = Libp2pHub._(server, ownRelay, relayDart, relayBrowser ?? ownRelay?.ws ?? '',
        relay ?? ownRelay!.lanTcp ?? ownRelay!.tcp, host, webrtc, driver, pages, log);
    log('hub on port ${server.port}; relay for phones ${hub.relayForPhones}; '
        'Dart peer ${host.id}${driver == null ? '' : '; browser ${driver.description}'}');
    return hub;
  }

  int get port => _server.port;

  /// Where phones reach the hub's Dart host over libp2p.
  String get dialBackAddress => '$relayForPhones/p2p-circuit/p2p/${_host.id}';

  /// Books the hub's reservation on the relay again (they last an hour).
  Future<void> refreshReservation() => reserveOn(_host, _relayDart);

  Future<void> close() async {
    await _server.close(force: true);
    await _browser?.close();
    await _pages.close(force: true);
    await _host.close();
    await _ownRelay?.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final reply = switch ((request.method, request.uri.path)) {
        ('GET', '/config') => {
            'relay': relayForPhones,
            'dartPeer': _host.id.toString(),
            'browser': _browser?.description,
          },
        ('POST', '/phone') => _register(await _body(request)),
        ('GET', '/status') => _sessions[request.uri.queryParameters['run']]?.toJson() ?? (throw ArgumentError('unknown run')),
        ('POST', '/report') => _report(await _body(request)),
        _ => throw ArgumentError('no ${request.method} ${request.uri.path}'),
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply));
    } catch (e) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('$e');
    }
    await request.response.close();
  }

  static Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;

  Map<String, Object> _register(Map<String, dynamic> body) {
    final run = '${_nextRun++}';
    final session = _sessions[run] = _Session(PeerId.fromString(body['peer'] as String), '${body['label']}');
    _log('[$run] phone ${session.label} ${session.peer}');
    unawaited(_dialPhone(run, session));
    return {'run': run};
  }

  /// A phone asking over libp2p: run the session, streaming results back
  /// on [stream] (which stays on the relayed connection).
  Future<void> _dialBack(P2PStream stream, PeerId peer) async {
    final request = jsonDecode(await LineReader(stream).next() ?? '{}') as Map<String, dynamic>;
    final run = '${_nextRun++}';
    final session = _sessions[run] = _Session(peer, '${request['label']}');
    _log('[$run] phone ${session.label} $peer (over libp2p)');
    session.listener = (direction, result) =>
        unawaited(stream.write(utf8.encode('${jsonEncode({'direction': direction, ...result.toJson()})}\n')).catchError((Object _) {}));
    await _dialPhone(run, session, fresh: false);
    try {
      await stream.write(utf8.encode('${jsonEncode({'browserPeer': session.browserPeer})}\n'));
      await stream.closeWrite();
    } catch (e) {
      _log('[$run] could not finish the session stream: $e');
    }
  }

  Future<void> _reportOverLibp2p(P2PStream stream, PeerId peer) async {
    final body = jsonDecode(await LineReader(stream).next() ?? '{}') as Map<String, dynamic>;
    final run = _sessions.entries.lastWhere((e) => e.value.peer == peer, orElse: () => MapEntry('?', _Session(peer, '?'))).key;
    _report({...body, 'run': run});
    await stream.close();
  }

  Future<void> _dialPhone(String run, _Session session, {bool fresh = true}) async {
    try {
      await runWebRtcChecks(_host, _webrtc, session.peer, _relayDart, fresh: fresh, onResult: (r) {
        session.dart.add(r);
        session.listener?.call('Dart → phone', r);
        _log('[$run] Dart → phone  $r');
      });
      final browser = _browser;
      if (browser != null) {
        final watch = Stopwatch()..start();
        session._browserWatch = watch;
        browser.open(Uri.parse('http://127.0.0.1:${_pages.port}/').replace(queryParameters: {
          'run': run,
          'target': '$_relayBrowser/p2p-circuit/webrtc/p2p/${session.peer}',
          'relay': _relayBrowser,
        }));
        await session.browserDone.future.timeout(const Duration(seconds: 120), onTimeout: () {
          final result = CheckResult('browser', false, 'no result within 120 s', watch.elapsed);
          session.browser.add(result);
          session.listener?.call('browser → phone', result);
        });
      }
    } catch (e) {
      session.dart.add(CheckResult('hub', false, '$e', Duration.zero));
    } finally {
      session.hubDone = true;
      _log('[$run] hub done; waiting for the phone to dial back');
    }
  }

  void _browserLog(String line) {
    final i = line.indexOf('RESULT ');
    if (i < 0) return;
    final json = jsonDecode(line.substring(i + 'RESULT '.length)) as Map<String, dynamic>;
    final run = json['run'] as String?;
    final session = _sessions[run];
    if (session == null) return;
    final name = json['name'] as String;
    if (name == 'listening') {
      session.browserPeer = json['detail'] as String;
      session.browserDone.complete();
      return;
    }
    if (name == 'done') return;
    final result = CheckResult(name, json['ok'] as bool, '${json['detail']}', session._browserWatch?.elapsed ?? Duration.zero);
    session.browser.add(result);
    session.listener?.call('browser → phone', result);
    _log('[$run] browser → phone  $result');
    if (name == 'fatal' && !session.browserDone.isCompleted) session.browserDone.complete();
  }

  Map<String, Object> _report(Map<String, dynamic> body) {
    final run = body['run'] as String;
    final results = (body['results'] as Map<String, dynamic>);
    for (final MapEntry(key: target, value: list) in results.entries) {
      for (final r in (list as List).cast<Map<String, dynamic>>()) {
        _log('[$run] phone → $target  ${CheckResult.fromJson(r)}');
      }
    }
    final all = results.values.expand((l) => l as List).cast<Map<String, dynamic>>();
    final hub = _sessions[run];
    final hubResults = [...?hub?.dart, ...?hub?.browser];
    _log('[$run] ${body['label']}: phone ${all.where((r) => r['ok'] == true).length}/${all.length}, '
        'hub ${hubResults.where((r) => r.ok).length}/${hubResults.length}');
    return {'ok': true};
  }
}

class _Session {
  final PeerId peer;
  final String label;
  final dart = <CheckResult>[];
  final browser = <CheckResult>[];
  final browserDone = Completer<void>();
  Stopwatch? _browserWatch;
  String? browserPeer;

  /// Streams results to a phone that asked over libp2p.
  void Function(String direction, CheckResult result)? listener;
  bool hubDone = false;

  _Session(this.peer, this.label);

  Map<String, Object?> toJson() => {
        'hubDone': hubDone,
        'browserPeer': browserPeer,
        'dart': [for (final r in dart) r.toJson()],
        'browser': [for (final r in browser) r.toJson()],
      };
}
