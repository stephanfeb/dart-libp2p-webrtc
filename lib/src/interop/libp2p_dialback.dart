// Test coordination over libp2p itself, for phones that cannot reach the
// desktop hub's HTTP API (e.g. on cellular, with only a public relay in
// common): the phone asks the hub's Dart host to dial it back over WebRTC
// and gets the results on the same stream, then reports its own.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/stream.dart';

import '../libp2p/webrtc_transport.dart';
import 'libp2p_checks.dart';

/// Request: one JSON line `{"label": …}`. Reply: one JSON line per
/// [CheckResult] as the hub's checks run, then end of stream.
const dialBackProtocol = '/webrtc-interop/dial-back/1.0.0';

/// One JSON line `{"label": …, "results": [CheckResult…]}`; no reply.
const reportProtocol = '/webrtc-interop/report/1.0.0';

/// Serves [dialBackProtocol] and [reportProtocol] on [host]: a requester is
/// dialed back over WebRTC, signaling through the relay at [relayAddr].
void serveDialBack(Host host, WebRtcTransport webrtc, String relayAddr, {void Function(String line) log = print}) {
  var nextRun = 0;
  host.setStreamHandler(dialBackProtocol, (stream, peer) async {
    final run = 'r${nextRun++}';
    final lines = LineReader(stream);
    try {
      final request = jsonDecode(await lines.next() ?? '{}') as Map<String, dynamic>;
      log('[$run] ${request['label']} $peer asks for a dial-back');
      // Keep the relayed connection: this stream runs on it.
      await runWebRtcChecks(host, webrtc, peer, relayAddr, fresh: false, onResult: (r) {
        log('[$run] Dart → phone  $r');
        unawaited(stream.write(utf8.encode('${jsonEncode(r.toJson())}\n')).catchError((Object _) {}));
      });
      await stream.closeWrite();
    } catch (e) {
      log('[$run] dial-back failed: $e');
      await stream.reset();
    }
  });
  host.setStreamHandler(reportProtocol, (stream, peer) async {
    final report = jsonDecode(await LineReader(stream).next() ?? '{}') as Map<String, dynamic>;
    final raw = report['results'];
    final list = raw is Map ? (raw['Dart'] as List? ?? const []) : (raw as List? ?? const []);
    final results = [for (final r in list) CheckResult.fromJson(r as Map<String, dynamic>)];
    for (final r in results) {
      log('[${report['label']}] phone → Dart  $r');
    }
    log('[${report['label']}] phone → Dart ${results.where((r) => r.ok).length}/${results.length}');
    await stream.close();
  });
}

/// Newline-delimited text from a stream.
class LineReader {
  final P2PStream _stream;
  final _buffer = BytesBuilder();

  LineReader(this._stream);

  /// The next line, or null at end of stream.
  Future<String?> next() async {
    while (true) {
      final bytes = _buffer.toBytes();
      final newline = bytes.indexOf(10);
      if (newline >= 0) {
        _buffer
          ..clear()
          ..add(bytes.sublist(newline + 1));
        return utf8.decode(bytes.sublist(0, newline));
      }
      final chunk = await _stream.read();
      if (chunk.isEmpty) {
        _buffer.clear();
        return bytes.isEmpty ? null : utf8.decode(bytes);
      }
      _buffer.add(chunk);
    }
  }
}
