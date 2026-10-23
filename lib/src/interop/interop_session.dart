import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../ffi/rtc_peer_connection.dart';
import '../ffi/rtc_runtime.dart';

/// Thrown when a scenario's checks fail.
class InteropFailure implements Exception {
  final String message;

  InteropFailure(this.message);

  @override
  String toString() => message;
}

/// The Dart peer's end of one scenario's signaling, relayed to the browser
/// page by [InteropServer]. JSON messages:
///   {type: 'offer'|'answer', sdp}  {type: 'candidate', candidate, mid}
///   {type: 'result', ok, detail}   (browser → Dart, the page's verdict)
class InteropSession {
  final WebSocket _ws;
  final _descriptions = StreamController<Map<String, dynamic>>();
  late final _descriptionQueue = StreamIterator(_descriptions.stream);
  final _pendingCandidates = <(String, String?)>[];
  final _result = Completer<Map<String, dynamic>>();
  RtcPeerConnection? _pc;

  /// Browser candidates libdatachannel rejected.
  final rejectedCandidates = <String>[];

  /// Browser candidates received, for reporting.
  final browserCandidates = <String>[];

  InteropSession(this._ws) {
    _ws.listen(
      (data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        switch (msg['type']) {
          case 'offer' || 'answer':
            _descriptions.add(msg);
          case 'candidate':
            final candidate = msg['candidate'] as String?;
            if (candidate == null || candidate.isEmpty) return; // end of candidates
            browserCandidates.add(candidate);
            _pendingCandidates.add((candidate, msg['mid'] as String?));
            _flushCandidates();
          case 'result':
            if (!_result.isCompleted) _result.complete(msg);
        }
      },
      onDone: () {
        if (!_result.isCompleted) {
          _result.completeError(InteropFailure('signaling closed before the browser reported'));
          _result.future.ignore();
        }
      },
    );
  }

  /// Connects to [InteropServer] for one run of [scenario]. The browser
  /// page uses the same [iceServers] (STUN/TURN URLs).
  static Future<InteropSession> connect(
    Uri server,
    String scenario,
    String runId, {
    List<String> iceServers = const [],
  }) async {
    final uri = server.replace(
      path: '/signal',
      queryParameters: {
        'role': 'dart',
        'scenario': scenario,
        'run': runId,
        if (iceServers.isNotEmpty) 'ice': iceServers.join(','),
      },
    );
    return InteropSession(await WebSocket.connect(uri.toString()));
  }

  void _send(Map<String, Object?> msg) => _ws.add(jsonEncode(msg));

  Future<String> _nextDescription(String type) async {
    if (!await _descriptionQueue.moveNext()) throw InteropFailure('signaling closed');
    final msg = _descriptionQueue.current;
    if (msg['type'] != type) throw InteropFailure('expected $type, got ${msg['type']}');
    return msg['sdp'] as String;
  }

  /// Candidates apply only once the remote description is set.
  void _flushCandidates() {
    final pc = _pc;
    if (pc == null) return;
    for (final (candidate, mid) in _pendingCandidates) {
      try {
        pc.addRemoteCandidate(candidate, mid);
      } on RtcException {
        rejectedCandidates.add(candidate);
      }
    }
    _pendingCandidates.clear();
  }

  /// Answers the browser's offer with [pc].
  Future<void> answer(RtcPeerConnection pc) async {
    pc.setRemoteDescription(await _nextDescription('offer'), 'offer');
    _pc = pc;
    _flushCandidates();
    _send({'type': 'answer', 'sdp': await pc.createAnswer()});
  }

  /// Sends an offer from [pc] and applies the browser's answer.
  Future<void> offer(RtcPeerConnection pc) async {
    _send({'type': 'offer', 'sdp': await pc.createOffer()});
    pc.setRemoteDescription(await _nextDescription('answer'), 'answer');
    _pc = pc;
    _flushCandidates();
  }

  /// The page's verdict; throws [InteropFailure] unless it is ok.
  Future<String> browserVerdict() async {
    final result = await _result.future;
    final detail = '${result['detail']}';
    if (result['ok'] != true) throw InteropFailure('browser: $detail');
    return detail;
  }

  Future<void> close() async {
    await _descriptionQueue.cancel();
    await _ws.close();
  }
}
