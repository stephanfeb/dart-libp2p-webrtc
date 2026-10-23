import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../ffi/rtc_data_channel.dart';
import '../ffi/rtc_peer_connection.dart';
import 'interop_session.dart';

/// The Dart peer's half of a scenario; the browser half is in
/// interop/browser/page.js under the same name. Returns a detail line, or
/// throws [InteropFailure].
typedef Scenario = Future<String> Function(InteropSession session, RtcPeerConnection pc);

/// Outcome of one scenario run.
class ScenarioReport {
  final String name;
  final bool ok;
  final String detail;
  final Duration elapsed;

  /// `ip:port` of the browser as seen by ICE, if the connection came up.
  final String? remoteAddress;

  /// Browser candidate types (host/srflx/relay, mDNS or not), e.g. `host(mdns)`.
  final List<String> browserCandidateTypes;
  final List<String> rejectedCandidates;

  /// Full ICE candidate lines on each side, for diagnosing failed connections.
  final List<String> localCandidates;
  final List<String> browserCandidates;

  ScenarioReport({
    required this.name,
    required this.ok,
    required this.detail,
    required this.elapsed,
    this.remoteAddress,
    this.browserCandidateTypes = const [],
    this.rejectedCandidates = const [],
    this.localCandidates = const [],
    this.browserCandidates = const [],
  });

  @override
  String toString() => '${ok ? 'PASS' : 'FAIL'} $name (${elapsed.inMilliseconds} ms'
      '${remoteAddress == null ? '' : ', via $remoteAddress'}): $detail';
}

/// Runs [name] against the browser paired by the [InteropServer] at [server].
Future<ScenarioReport> runScenario(
  String name,
  Uri server, {
  RtcConfig config = const RtcConfig(),
  Duration timeout = const Duration(seconds: 45),
}) async {
  final scenario = scenarios[name] ?? (throw ArgumentError('unknown scenario $name'));
  final runId = _runId();
  final stopwatch = Stopwatch()..start();
  InteropSession? session;
  RtcPeerConnection? pc;
  var ok = false;
  String detail;
  try {
    session = await InteropSession.connect(server, name, runId, iceServers: config.iceServers);
    pc = RtcPeerConnection(config);
    detail = await scenario(session, pc).timeout(timeout);
    ok = true;
  } on TimeoutException {
    detail = 'timed out after ${timeout.inSeconds} s (peer state ${pc?.state.name})';
  } catch (e) {
    detail = '$e';
  }
  final report = ScenarioReport(
    name: name,
    ok: ok,
    detail: detail,
    elapsed: stopwatch.elapsed,
    remoteAddress: pc?.state == RtcPeerState.connected ? pc?.remoteAddress : null,
    browserCandidateTypes: [...?session?.browserCandidates.map(_candidateType)],
    rejectedCandidates: [...?session?.rejectedCandidates],
    localCandidates: pc == null ? const [] : _localCandidates(pc),
    browserCandidates: [...?session?.browserCandidates],
  );
  await pc?.close();
  await session?.close();
  return report;
}

/// Scenario names, in run order.
final Map<String, Scenario> scenarios = {
  // Browser offers and opens a channel; Dart echoes.
  'browser-offers-echo': (session, pc) async {
    pc.onDataChannel.listen((dc) => dc.messages.listen(dc.send));
    await session.answer(pc);
    return session.browserVerdict();
  },

  // Dart offers and opens the channel; the browser echoes and Dart checks.
  'dart-offers-echo': (session, pc) async {
    final dc = pc.createDataChannel('echo');
    await session.offer(pc);
    await dc.opened;
    final sent = [for (final (i, n) in [1, 100, 1024, 16 * 1024].indexed) pattern(i * 100000, n)];
    final echoed = dc.messages.take(sent.length).toList();
    for (final m in sent) {
      await dc.send(m);
    }
    final replies = await echoed;
    for (var i = 0; i < sent.length; i++) {
      if (!_bytesEqual(sent[i], replies[i])) throw InteropFailure('echo $i differs');
    }
    return '${sent.length} echoes verified';
  },

  // Pre-negotiated stream 0 (libp2p /webrtc-direct's Noise channel).
  'negotiated-stream-0': (session, pc) async {
    final dc = pc.createDataChannel('', negotiated: true, stream: 0);
    dc.messages.listen(dc.send);
    await session.answer(pc);
    final detail = await session.browserVerdict();
    if (dc.streamId != 0) throw InteropFailure('stream id ${dc.streamId}');
    return detail;
  },

  // 4 MiB browser → Dart; Dart verifies every byte and replies.
  'bulk-browser-to-dart': (session, pc) async {
    pc.onDataChannel.listen((dc) {
      var offset = 0;
      String? error;
      dc.messages.listen((chunk) async {
        if (error == null && !_bytesEqual(chunk, pattern(offset, chunk.length))) {
          error = 'mismatch near offset $offset';
        }
        offset += chunk.length;
        if (offset == _bulkBytes) await dc.send(utf8.encode(error ?? 'ok $offset'));
      });
    });
    await session.answer(pc);
    return session.browserVerdict();
  },

  // 4 MiB Dart → browser through send backpressure.
  'bulk-dart-to-browser': (session, pc) async {
    final sent = Completer<Duration>();
    pc.onDataChannel.listen((dc) async {
      await dc.messages.first; // "go"
      final stopwatch = Stopwatch()..start();
      const chunk = 16 * 1024;
      for (var offset = 0; offset < _bulkBytes; offset += chunk) {
        await dc.send(pattern(offset, chunk));
      }
      sent.complete(stopwatch.elapsed);
    });
    await session.answer(pc);
    final detail = await session.browserVerdict();
    final seconds = (await sent.future).inMilliseconds / 1000;
    return '$detail; queued in ${seconds.toStringAsFixed(2)} s';
  },

  // 16 browser-opened channels, each echoed.
  'many-channels': (session, pc) async {
    pc.onDataChannel.listen((dc) => dc.messages.listen(dc.send));
    await session.answer(pc);
    return session.browserVerdict();
  },

  // Dart closes a channel; the browser must see it close.
  'dart-closes-channel': (session, pc) async {
    pc.onDataChannel.listen((RtcDataChannel dc) async {
      await dc.messages.first;
      await dc.close();
    });
    await session.answer(pc);
    return session.browserVerdict();
  },
};

const _bulkBytes = 4 * 1024 * 1024;

/// Byte at absolute stream offset o is (o*31+7)&255; matches page.js.
Uint8List pattern(int offset, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = ((offset + i) * 31 + 7) & 255;
  }
  return out;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// `typ` of an ICE candidate line, marking mDNS hosts: `host(mdns)`, `srflx`, …
String _candidateType(String candidate) {
  final parts = candidate.split(' ');
  final typIndex = parts.indexOf('typ');
  final type = typIndex >= 0 && typIndex + 1 < parts.length ? parts[typIndex + 1] : '?';
  final address = parts.length > 4 ? parts[4] : '';
  final transport = parts.length > 2 ? parts[2].toLowerCase() : '?';
  return '$type${address.endsWith('.local') ? '(mdns)' : ''}/$transport';
}

/// Candidate lines from our local SDP; empty if none was created.
List<String> _localCandidates(RtcPeerConnection pc) {
  try {
    return [
      for (final line in const LineSplitter().convert(pc.localDescription))
        if (line.startsWith('a=candidate:')) line.substring(2),
    ];
  } on Object {
    return const [];
  }
}

String _runId() {
  final random = Random();
  return List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join();
}
