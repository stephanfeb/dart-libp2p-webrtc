// Circuit relay v2 servers from other libp2p implementations, as separate
// processes: js-libp2p (interop/browser/relay.mjs) and go-libp2p
// (interop/go/relay), each listening on loopback TCP and WebSockets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_webrtc/interop.dart';

final _browserDir = Directory('interop/browser');
final _goDir = Directory('interop/go');

class ExternalRelay {
  final String kind;
  final PeerId peerId;

  /// `/ip4/127.0.0.1/tcp/<port>/p2p/<id>`, for Dart hosts.
  final String tcp;

  /// `/ip4/127.0.0.1/tcp/<port>/ws/p2p/<id>`, for browsers.
  final String ws;

  final Process _process;

  ExternalRelay._(this.kind, this.peerId, this.tcp, this.ws, this._process);

  /// Why [kind] can't run here, or null if it can.
  static Future<String?> unavailable(String kind) async {
    switch (kind) {
      case 'js':
        if (!BrowserDriver.isInstalled(_browserDir)) return 'run npm install in interop/browser';
        try {
          final version = await Process.run(nodeExecutable, ['--version']);
          final major = int.tryParse(RegExp(r'^v(\d+)').firstMatch('${version.stdout}')?.group(1) ?? '');
          if (major == null || major < 22) {
            return 'needs Node 22+ (found ${major ?? 'none'}); set NODE to a newer node binary';
          }
        } on ProcessException {
          return 'needs Node 22+; set NODE to a node binary';
        }
        return null;
      case 'go':
        try {
          final build = await Process.run('go', ['build', '-o', 'build/relay', './relay'], workingDirectory: _goDir.path);
          return build.exitCode == 0 ? null : 'go build of interop/go/relay failed:\n${build.stderr}';
        } on ProcessException {
          return 'needs Go to build interop/go/relay';
        }
      default:
        throw ArgumentError('unknown relay kind $kind');
    }
  }

  /// Starts the relay; [unavailable] must have returned null.
  static Future<ExternalRelay> start(String kind) async {
    final process = kind == 'js'
        ? await Process.start(nodeExecutable, ['relay.mjs'], workingDirectory: _browserDir.path)
        : await Process.start('build/relay', const [], workingDirectory: _goDir.path);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    final first = Completer<Map<String, dynamic>>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (!first.isCompleted) first.complete(jsonDecode(line) as Map<String, dynamic>);
    });
    final info = await first.future.timeout(const Duration(seconds: 20));
    final addrs = (info['addrs'] as List).cast<String>();
    return ExternalRelay._(
      kind,
      PeerId.fromString(info['peerId'] as String),
      addrs.firstWhere((a) => !a.contains('/ws')),
      addrs.firstWhere((a) => a.contains('/ws')),
      process,
    );
  }

  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      _process.kill();
      return -1;
    });
  }
}
