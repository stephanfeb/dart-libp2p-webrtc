import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The Node.js binary for the interop harness: `NODE` if set, else `node`.
/// The js-libp2p relay needs Node 22+.
String get nodeExecutable => Platform.environment['NODE'] ?? 'node';

/// Runs interop/browser/run.mjs (Playwright), which opens each URL passed to
/// [open] in a fresh page of one browser.
class BrowserDriver {
  final Process _process;

  /// e.g. `chrome 156.0.8078.48`.
  final String description;

  BrowserDriver._(this._process, this.description);

  /// [browser] is chrome (the installed Chrome), chromium, firefox or webkit.
  /// [onLog] receives the pages' console output.
  static Future<BrowserDriver> start({
    required Directory driverDir,
    String browser = 'chrome',
    void Function(String line)? onLog,
  }) async {
    final process = await Process.start(
      nodeExecutable,
      ['run.mjs'],
      workingDirectory: driverDir.path,
      environment: {'BROWSER': browser},
    );
    final ready = Completer<String>();
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (!ready.isCompleted && line.startsWith('READY ')) {
        ready.complete(line.substring('READY '.length));
      } else {
        onLog?.call(line);
      }
    });
    unawaited(process.exitCode.then((code) {
      if (!ready.isCompleted) ready.completeError(StateError('browser driver exited ($code)'));
    }));
    return BrowserDriver._(process, await ready.future.timeout(const Duration(seconds: 30)));
  }

  /// Whether the Playwright driver is installed in [driverDir].
  static bool isInstalled(Directory driverDir) =>
      Directory('${driverDir.path}/node_modules/playwright').existsSync();

  void open(Uri url) => _process.stdin.writeln(url);

  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      _process.kill();
      return -1;
    });
  }
}
