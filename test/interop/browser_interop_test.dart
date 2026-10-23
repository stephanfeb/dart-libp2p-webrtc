// Interop between this package's libdatachannel layer and a real browser's
// RTCPeerConnection (the installed Chrome by default; set
// BROWSER=chromium|firefox|webkit).
//
// The same scenarios run on phones via example/interop_app.
//
// Setup: (cd interop/browser && npm install)
@Tags(['browser'])
library;

import 'dart:io';

import 'package:dart_libp2p_webrtc/interop.dart';
import 'package:test/test.dart';

final _driverDir = Directory('interop/browser');

void main() {
  late BrowserDriver driver;
  late InteropServer server;

  setUpAll(() async {
    driver = await BrowserDriver.start(
      driverDir: _driverDir,
      browser: Platform.environment['BROWSER'] ?? 'chrome',
      onLog: (line) => print('  $line'),
    );
    print('browser: ${driver.description}');
    server = await InteropServer.start(
      pageScript: File('${_driverDir.path}/page.js'),
      openPage: driver.open,
      address: InternetAddress.loopbackIPv4,
    );
  });

  tearDownAll(() async {
    await server.close();
    await driver.close();
  });

  group('browser interop',
      skip: BrowserDriver.isInstalled(_driverDir) ? false : 'run npm install in interop/browser', () {
    for (final name in scenarios.keys) {
      test(name, () async {
        final report = await runScenario(name, Uri.parse('ws://127.0.0.1:${server.port}'));
        print('  $report');
        if (report.browserCandidateTypes.isNotEmpty) {
          print('  browser candidates: ${report.browserCandidateTypes.join(', ')}');
        }
        expect(report.ok, isTrue, reason: report.detail);
      });
    }
  });
}
