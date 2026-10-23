// The phone side of the libp2p tests against a desktop hub: reserve on the
// hub's relay, let the hub dial in over /webrtc, then dial it.
//
// Two ways to reach the hub: its HTTP API (lib/src/interop/libp2p_hub.dart;
// LAN, with a browser too), or libp2p itself through a public relay
// (lib/src/interop/libp2p_dialback.dart; any network, Dart host only).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';

import '../ffi/rtc_peer_connection.dart';
import '../libp2p/webrtc_transport.dart';
import 'libp2p_checks.dart';
import 'libp2p_dialback.dart';

/// Results of one session, by direction.
class PhoneSessionReport {
  final String label;
  String? relay;
  String? localPeer;
  String? error;
  final dartToPhone = <CheckResult>[];
  final browserToPhone = <CheckResult>[];
  final phoneToDart = <CheckResult>[];
  final phoneToBrowser = <CheckResult>[];

  PhoneSessionReport(this.label);

  Map<String, List<CheckResult>> get sections => {
        'Dart → phone': dartToPhone,
        'browser → phone': browserToPhone,
        'phone → Dart': phoneToDart,
        'phone → browser': phoneToBrowser,
      };

  Iterable<CheckResult> get all => sections.values.expand((s) => s);

  @override
  String toString() => [
        'libp2p session $label: ${all.where((r) => r.ok).length}/${all.length} ok',
        if (localPeer != null) 'phone $localPeer, relay $relay',
        if (error != null) 'error: $error',
        for (final MapEntry(key: name, value: results) in sections.entries)
          if (results.isNotEmpty) ...[name, for (final r in results) '  $r'],
      ].join('\n');
}

/// Runs a session against [hub]: the HTTP hub (`http://host:8788`), or the
/// hub's Dart peer through a relay
/// (`/ip4/…/udp/…/udx/p2p/<relay>/p2p-circuit/p2p/<hub>`). [onUpdate] is
/// called whenever a result arrives.
Future<PhoneSessionReport> runPhoneSession(
  String hub, {
  required String label,
  RtcConfig rtcConfig = const RtcConfig(),
  void Function(PhoneSessionReport report)? onUpdate,
}) {
  if (hub.startsWith('/')) {
    return _sessionOverLibp2p(hub, label: label, rtcConfig: rtcConfig, onUpdate: onUpdate);
  }
  final uri = Uri.tryParse(hub);
  if (uri == null || !uri.hasAuthority) throw ArgumentError('hub must be http://host:port or a multiaddr');
  return _sessionOverHttp(uri, label: label, rtcConfig: rtcConfig, onUpdate: onUpdate);
}

Future<PhoneSessionReport> _sessionOverLibp2p(
  String hubAddr, {
  required String label,
  required RtcConfig rtcConfig,
  void Function(PhoneSessionReport report)? onUpdate,
}) async {
  final report = PhoneSessionReport(label);
  void update() => onUpdate?.call(report);
  final circuit = hubAddr.indexOf('/p2p-circuit/p2p/');
  if (circuit < 0) throw ArgumentError('expected <relay>/p2p-circuit/p2p/<hub>, got $hubAddr');
  final relay = report.relay = hubAddr.substring(0, circuit);
  final hubPeer = PeerId.fromString(hubAddr.substring(circuit + '/p2p-circuit/p2p/'.length));

  late final Host host;
  late final WebRtcTransport webrtc;
  try {
    (host, webrtc) = await createTestHost(rtcConfig: rtcConfig);
  } catch (e) {
    report.error = '$e';
    return report;
  }
  try {
    report.localPeer = '${host.id}';
    update();
    await reserveOn(host, relay);

    // The hub dials us back over WebRTC, reporting on this stream (which
    // stays on the relayed connection).
    await host.connect(AddrInfo(hubPeer, [MultiAddr('$relay/p2p-circuit')]));
    final stream = await host.newStream(hubPeer, [dialBackProtocol], Context());
    await stream.write(utf8.encode('${jsonEncode({'label': label})}\n'));
    // Lines are results (with the direction; Dart → phone if none), then
    // possibly {browserPeer} when the hub has a browser.
    final lines = LineReader(stream);
    String? browserPeer;
    while (true) {
      final line = await lines.next().timeout(const Duration(minutes: 4));
      if (line == null) break;
      final json = jsonDecode(line) as Map<String, dynamic>;
      if (json.containsKey('browserPeer')) {
        browserPeer = json['browserPeer'] as String?;
        continue;
      }
      final target = json['direction'] == 'browser → phone' ? report.browserToPhone : report.dartToPhone;
      target.add(CheckResult.fromJson(json));
      update();
    }

    // Now we dial the hub's Dart host, then its browser.
    await runWebRtcChecks(host, webrtc, hubPeer, relay, onResult: (r) {
      report.phoneToDart.add(r);
      update();
    });
    if (browserPeer != null) {
      await runWebRtcChecks(host, webrtc, PeerId.fromString(browserPeer), relay, onResult: (r) {
        report.phoneToBrowser.add(r);
        update();
      });
    }
    final out = await host.newStream(hubPeer, [reportProtocol], Context());
    await out.write(utf8.encode('${jsonEncode({
      'label': label,
      'results': {
        'Dart': [for (final r in report.phoneToDart) r.toJson()],
        'browser': [for (final r in report.phoneToBrowser) r.toJson()],
      },
    })}\n'));
    await out.closeWrite();
  } catch (e) {
    report.error = '$e';
    update();
  } finally {
    await host.close();
  }
  return report;
}

Future<PhoneSessionReport> _sessionOverHttp(
  Uri hub, {
  required String label,
  required RtcConfig rtcConfig,
  void Function(PhoneSessionReport report)? onUpdate,
}) async {
  final report = PhoneSessionReport(label);
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  void update() => onUpdate?.call(report);

  Future<Map<String, dynamic>> call(String method, String path, [Map<String, Object?>? body]) async {
    final request = await http.openUrl(method, hub.resolve(path));
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    if (response.statusCode != HttpStatus.ok) throw HttpException('$method $path: $text');
    return jsonDecode(text) as Map<String, dynamic>;
  }

  final (host, webrtc) = await createTestHost(rtcConfig: rtcConfig);
  try {
    final config = await call('GET', '/config');
    final relay = report.relay = config['relay'] as String;
    report.localPeer = '${host.id}';
    update();
    await reserveOn(host, relay);
    final run = (await call('POST', '/phone', {'peer': '${host.id}', 'label': label}))['run'] as String;

    // The hub dials us; follow its results until it is done.
    Map<String, dynamic> status;
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (true) {
      status = await call('GET', '/status?run=$run');
      List<CheckResult> parse(String key) =>
          [for (final r in (status[key] as List).cast<Map<String, dynamic>>()) CheckResult.fromJson(r)];
      report.dartToPhone
        ..clear()
        ..addAll(parse('dart'));
      report.browserToPhone
        ..clear()
        ..addAll(parse('browser'));
      update();
      if (status['hubDone'] == true) break;
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('the hub did not finish');
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    // Now we dial: the hub's Dart host, then its browser.
    await runWebRtcChecks(host, webrtc, PeerId.fromString(config['dartPeer'] as String), relay, onResult: (r) {
      report.phoneToDart.add(r);
      update();
    });
    final browserPeer = status['browserPeer'] as String?;
    if (browserPeer != null) {
      await runWebRtcChecks(host, webrtc, PeerId.fromString(browserPeer), relay, onResult: (r) {
        report.phoneToBrowser.add(r);
        update();
      });
    }
    await call('POST', '/report', {
      'run': run,
      'label': label,
      'results': {
        'Dart': [for (final r in report.phoneToDart) r.toJson()],
        'browser': [for (final r in report.phoneToBrowser) r.toJson()],
      },
    });
  } catch (e) {
    report.error = '$e';
    update();
  } finally {
    http.close(force: true);
    await host.close();
  }
  return report;
}
