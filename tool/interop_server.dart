// Signaling relay + browser for running the interop scenarios from a phone
// (example/interop_app). The browser runs on this machine via Playwright.
//
//   (cd interop/browser && npm install)
//   dart run tool/interop_server.dart [--port 8787] [--browser chrome|chromium|firefox|webkit]
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_libp2p_webrtc/interop.dart';

Future<void> main(List<String> args) async {
  final options = (ArgParser()
        ..addOption('port', defaultsTo: '8787')
        ..addOption('browser', defaultsTo: 'chrome', allowed: ['chrome', 'chromium', 'firefox', 'webkit'])
        ..addFlag('verbose', abbr: 'v', help: 'Print browser console output'))
      .parse(args);

  final driverDir = Directory('interop/browser');
  if (!BrowserDriver.isInstalled(driverDir)) {
    stderr.writeln('Run `npm install` in interop/browser first.');
    exit(1);
  }
  final verbose = options.flag('verbose');
  final driver = await BrowserDriver.start(
    driverDir: driverDir,
    browser: options.option('browser')!,
    onLog: (line) {
      if (verbose || line.contains('connectionState=') || line.contains('error')) print(line);
    },
  );
  final server = await InteropServer.start(
    pageScript: File('${driverDir.path}/page.js'),
    openPage: (url) {
      print('run ${url.queryParameters['scenario']} (${url.queryParameters['run']})');
      driver.open(url);
    },
    port: int.parse(options.option('port')!),
  );

  print('Browser: ${driver.description}');
  print('Point the app at one of:');
  for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final address in interface.addresses) {
      print('  ws://${address.address}:${server.port}   (${interface.name})');
    }
  }

  await ProcessSignal.sigint.watch().first;
  print('Shutting down');
  await server.close();
  await driver.close();
  exit(0);
}
