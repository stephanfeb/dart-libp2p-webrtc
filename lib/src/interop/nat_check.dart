import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Public STUN servers from different operators, so a NAT that maps per
/// destination shows different public ports.
const defaultStunServers = [
  'stun.l.google.com:19302',
  'stun.cloudflare.com:3478',
  'global.stun.twilio.com:3478',
];

/// What one STUN server reported for our socket.
class StunMapping {
  final String server;
  final InternetAddress? serverAddress;

  /// Our address and port as the server saw them; null if it didn't answer.
  final InternetAddress? mappedAddress;
  final int? mappedPort;
  final Duration? rtt;
  final String? error;

  StunMapping(this.server,
      {this.serverAddress, this.mappedAddress, this.mappedPort, this.rtt, this.error});

  bool get ok => mappedAddress != null;

  @override
  String toString() => ok
      ? '$server (${serverAddress?.address}) → ${mappedAddress!.address}:$mappedPort '
          'in ${rtt!.inMilliseconds} ms'
      : '$server → ${error ?? 'no answer'}';
}

/// Mapping behaviour of the NAT in front of one socket (RFC 4787 terms).
/// Filtering behaviour isn't measured: that needs a server supporting
/// RFC 5780 CHANGE-REQUEST, which the public ones don't.
class NatCheckResult {
  final InternetAddressType family;

  /// Addresses on this device's interfaces (IPv6 hosts often have several).
  final Set<InternetAddress> localAddresses;
  final int localPort;
  final List<StunMapping> mappings;

  NatCheckResult(this.family, this.localAddresses, this.localPort, this.mappings);

  List<StunMapping> get answered => [for (final m in mappings) if (m.ok) m];

  /// One-line summary.
  String get verdict {
    final got = answered;
    if (got.isEmpty) return 'no STUN server answered (no route, UDP blocked, or no connectivity)';
    // An IPv6 socket that the servers see as IPv4 went through NAT64.
    final nat64 = family == InternetAddressType.IPv6 &&
        got.every((m) => m.mappedAddress!.type == InternetAddressType.IPv4);
    final summary = _mappingVerdict(got);
    return nat64 ? 'IPv4 via NAT64: $summary' : summary;
  }

  String _mappingVerdict(List<StunMapping> got) {
    final endpoints = {for (final m in got) '${m.mappedAddress!.address}:${m.mappedPort}'};
    final noNat = got.every((m) => m.mappedPort == localPort && localAddresses.contains(m.mappedAddress));
    if (noNat) return 'no NAT: servers see this device\'s own address and port (a firewall may still filter)';
    final preserved = got.every((m) => m.mappedPort == localPort);
    if (got.length < 2) {
      return 'NAT present, mapping type unknown (only one server answered)'
          '${preserved ? ', port preserved' : ''}';
    }
    if (endpoints.length == 1) {
      return 'endpoint-independent mapping ("cone"): same public port for every server'
          '${preserved ? ', port preserved' : ''} — hole punching can work';
    }
    final addresses = {for (final m in got) m.mappedAddress!.address};
    return 'address-dependent mapping ("symmetric"): ${endpoints.length} different public '
        '${addresses.length > 1 ? 'addresses/ports' : 'ports'} for ${got.length} servers — '
        'hole punching fails against restricted NATs; needs TURN or a relay';
  }

  @override
  String toString() => [
        '${family == InternetAddressType.IPv4 ? 'IPv4' : 'IPv6'} local port $localPort: $verdict',
        for (final m in mappings) '  $m',
      ].join('\n');
}

/// Asks each of [servers] for our public address from one UDP socket.
Future<NatCheckResult> checkNat({
  InternetAddressType family = InternetAddressType.IPv4,
  List<String> servers = defaultStunServers,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final socket = await RawDatagramSocket.bind(
      family == InternetAddressType.IPv4 ? InternetAddress.anyIPv4 : InternetAddress.anyIPv6, 0);
  final pending = <String, Completer<(InternetAddress, int)>>{}; // by transaction id
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    final parsed = _parseResponse(datagram.data);
    if (parsed == null) return;
    final (txId, address, port) = parsed;
    final completer = pending.remove(txId);
    if (completer != null && !completer.isCompleted) completer.complete((address, port));
  });

  try {
    final mappings = await Future.wait(servers.map((server) async {
      final (host, port) = _hostPort(server);
      final InternetAddress address;
      try {
        // Some OSes answer IPv6 lookups on IPv4-only networks with IPv4-mapped
        // addresses (::ffff:a.b.c.d), which would silently test IPv4 instead.
        final found = [
          for (final a in await InternetAddress.lookup(host, type: family))
            if (!_isV4Mapped(a)) a,
        ];
        if (found.isEmpty) return StunMapping(server, error: 'no ${family.name} route');
        address = found.first;
      } on SocketException catch (e) {
        return StunMapping(server, error: 'lookup failed: ${e.message}');
      }
      final (txId, request) = _bindingRequest();
      final completer = pending[txId] = Completer();
      final stopwatch = Stopwatch()..start();
      // Retransmit until answered or timed out.
      final sender = Timer.periodic(const Duration(milliseconds: 500), (_) {
        socket.send(request, address, port);
      });
      socket.send(request, address, port);
      try {
        final (mapped, mappedPort) = await completer.future.timeout(timeout);
        return StunMapping(server,
            serverAddress: address, mappedAddress: mapped, mappedPort: mappedPort, rtt: stopwatch.elapsed);
      } on TimeoutException {
        return StunMapping(server, serverAddress: address, error: 'timed out');
      } finally {
        sender.cancel();
        pending.remove(txId);
      }
    }));
    return NatCheckResult(family, await _localAddresses(family), socket.port, mappings);
  } finally {
    socket.close();
  }
}

const _magicCookie = 0x2112A442;

(String, int) _hostPort(String server) {
  final i = server.lastIndexOf(':');
  return (server.substring(0, i), int.parse(server.substring(i + 1)));
}

(String, Uint8List) _bindingRequest() {
  final random = Random.secure();
  final request = ByteData(20)
    ..setUint16(0, 0x0001) // Binding Request
    ..setUint16(2, 0) // no attributes
    ..setUint32(4, _magicCookie);
  for (var i = 8; i < 20; i++) {
    request.setUint8(i, random.nextInt(256));
  }
  final bytes = request.buffer.asUint8List();
  return (_hex(bytes.sublist(8, 20)), bytes);
}

/// Parses a Binding Success Response: (transaction id, mapped address, port).
(String, InternetAddress, int)? _parseResponse(Uint8List data) {
  if (data.length < 20) return null;
  final view = ByteData.sublistView(data);
  if (view.getUint16(0) != 0x0101 || view.getUint32(4) != _magicCookie) return null;
  final txId = data.sublist(8, 20);
  final end = min(20 + view.getUint16(2), data.length);
  (InternetAddress, int)? mapped;
  var offset = 20;
  while (offset + 4 <= end) {
    final type = view.getUint16(offset);
    final length = view.getUint16(offset + 2);
    final value = offset + 4;
    if (value + length > end) break;
    if (type == 0x0020) {
      // XOR-MAPPED-ADDRESS
      mapped = _readAddress(data, value, xor: true, txId: txId) ?? mapped;
    } else if (type == 0x0001 && mapped == null) {
      // MAPPED-ADDRESS (pre-RFC 5389 servers)
      mapped = _readAddress(data, value, xor: false, txId: txId);
    }
    offset = value + ((length + 3) & ~3);
  }
  if (mapped == null) return null;
  return (_hex(txId), mapped.$1, mapped.$2);
}

(InternetAddress, int)? _readAddress(Uint8List data, int at, {required bool xor, required Uint8List txId}) {
  final view = ByteData.sublistView(data);
  final family = data[at + 1];
  var port = view.getUint16(at + 2);
  final length = family == 0x01 ? 4 : 16;
  if (at + 4 + length > data.length) return null;
  final raw = Uint8List.fromList(data.sublist(at + 4, at + 4 + length));
  if (xor) {
    port ^= _magicCookie >> 16;
    final key = Uint8List(16)
      ..buffer.asByteData().setUint32(0, _magicCookie)
      ..setRange(4, 16, txId);
    for (var i = 0; i < length; i++) {
      raw[i] ^= key[i];
    }
  }
  return (InternetAddress.fromRawAddress(raw), port);
}

Future<Set<InternetAddress>> _localAddresses(InternetAddressType family) async {
  try {
    return {
      for (final interface in await NetworkInterface.list(type: family, includeLinkLocal: false))
        ...interface.addresses,
    };
  } on Object {
    return {};
  }
}

bool _isV4Mapped(InternetAddress a) {
  if (a.type != InternetAddressType.IPv6) return false;
  final raw = a.rawAddress;
  return raw.sublist(0, 10).every((b) => b == 0) && raw[10] == 0xff && raw[11] == 0xff;
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
