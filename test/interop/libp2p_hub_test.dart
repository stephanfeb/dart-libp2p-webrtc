// The phone libp2p flow on the desktop: the hub (go relay, Dart host,
// browser) and the phone's session code in one process.
@Tags(['browser'])
library;

import 'dart:io';

import 'package:dart_libp2p_webrtc/interop.dart';
import 'package:test/test.dart';

void main() {
  test('a phone session passes every check in all four directions', () async {
    final missing = await ExternalRelay.unavailable('go') ?? await ExternalRelay.unavailable('js');
    if (missing != null) return markTestSkipped(missing);
    final hub = await Libp2pHub.start(
      port: 0,
      relayTcpPort: 0,
      relayWsPort: 0,
      browser: Platform.environment['BROWSER'] ?? 'chrome',
    );
    addTearDown(hub.close);

    final report = await runPhoneSession('http://127.0.0.1:${hub.port}/', label: 'desktop');
    print(report);
    expect(report.error, isNull);
    for (final MapEntry(key: direction, value: results) in report.sections.entries) {
      expect(results, isNotEmpty, reason: direction);
      for (final r in results) {
        expect(r.ok, isTrue, reason: '$direction: $r');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('over libp2p through a go relay: dial-back, then the phone dials', () async {
    final missing = await ExternalRelay.unavailable('go');
    if (missing != null) return markTestSkipped(missing);
    final relay = await ExternalRelay.start('go');
    addTearDown(relay.close);
    final (hub, webrtc) = await createTestHost();
    addTearDown(hub.close);
    await reserveOn(hub, relay.tcp);
    final log = <String>[];
    serveDialBack(hub, webrtc, relay.tcp, log: log.add);

    final report = await runPhoneSession('${relay.tcp}/p2p-circuit/p2p/${hub.id}', label: 'desktop');
    print(report);
    expect(report.error, isNull);
    for (final direction in ['Dart → phone', 'phone → Dart']) {
      final results = report.sections[direction]!;
      expect(results, hasLength(6), reason: direction);
      expect(results.every((r) => r.ok), isTrue, reason: '$direction: $results');
    }
    // The hub logs the phone's report.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(log.last, contains('phone → Dart 6/6'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
