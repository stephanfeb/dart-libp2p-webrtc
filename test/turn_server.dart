// The TURN server for the fallback tests: docker/coturn/compose.yaml, or
// TURN_URL.
import 'dart:io';

String? _turnUrl;

/// `turn:user:pass@host:port`: TURN_URL, else the docker/coturn server on
/// loopback. Set by [turnUnavailable], which TURN tests call first.
///
/// Loopback keeps Docker Desktop's NAT off the relayed path: both peers
/// allocate on coturn, which relays between its own allocations. (On a
/// private address the relay's traffic to a peer leaves through that NAT
/// with rewritten ports, and browsers handle that unevenly.)
String get turnUrl => _turnUrl ?? (throw StateError('call turnUnavailable() first'));

/// Why the TURN server can't be used, or null. Checks its TCP listener.
Future<String?> turnUnavailable() async {
  _turnUrl ??= Platform.environment['TURN_URL'] ?? 'turn:test:test@127.0.0.1:3478';
  final uri = RegExp(r'@([^:]+):(\d+)').firstMatch(turnUrl);
  if (uri == null) return 'TURN_URL must look like turn:user:pass@host:port';
  try {
    final socket = await Socket.connect(uri.group(1), int.parse(uri.group(2)!), timeout: const Duration(seconds: 2));
    socket.destroy();
    return null;
  } on SocketException {
    return 'no TURN server at ${uri.group(1)}:${uri.group(2)}; '
        'run docker compose -f docker/coturn/compose.yaml up -d';
  }
}

/// [turnUrl] as libp2p-page.js takes it: `turn`, `turnUser`, `turnPass`.
Map<String, String> turnForBrowser() {
  final m = RegExp(r'^turn:([^:]+):([^@]+)@(.+)$').firstMatch(turnUrl)!;
  return {'turn': 'turn:${m.group(3)}', 'turnUser': m.group(1)!, 'turnPass': m.group(2)!};
}
