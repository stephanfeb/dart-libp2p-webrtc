// Two dart-libp2p hosts connect over TCP, run /webrtc-signaling/0.0.1 over
// that connection (standing in for a circuit relay), and then speak libp2p
// protocols, negotiated with multistream-select, over the WebRTC connection.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/mux.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p_webrtc/libp2p.dart';
import 'package:test/test.dart';

const _echo = '/test/echo/1.0.0';
const _hold = '/test/hold/1.0.0';
const _ping = '/ipfs/ping/1.0.0';

Future<Host> _host() async {
  final connManager = ConnectionManager();
  final host = await Libp2p.new_([
    Libp2p.connManager(connManager),
    Libp2p.transport(TCPTransport(connManager: connManager)),
    Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/tcp/0')]),
  ]);
  await host.start();
  return host;
}

/// Reads [stream] to EOF.
Future<Uint8List> _readAll(P2PStream stream) async {
  final out = BytesBuilder(copy: false);
  while (true) {
    final chunk = await stream.read();
    if (chunk.isEmpty) return out.takeBytes();
    out.add(chunk);
  }
}

Uint8List _random(int length, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => r.nextInt(256)));
}

void main() {
  late Host a;
  late Host b;
  late WebRtcConn aConn;
  late WebRtcConn bConn;
  final cleanup = <Future<void> Function()>[];
  late Completer<Object> holdOutcome;

  setUp(() async {
    a = await _host();
    cleanup.add(a.close);
    b = await _host();
    cleanup.add(b.close);
    holdOutcome = Completer();

    final answered = Completer<WebRtcConn>();
    b.setStreamHandler(signalingProtocol, (stream, peer) async {
      final conn = await answerWebRtc(stream);
      unawaited(conn.serveStreams(b.mux));
      answered.complete(conn);
    });
    // Echoes everything until the remote half-closes.
    b.setStreamHandler(_echo, (stream, peer) async {
      await stream.write(await _readAll(stream));
      await stream.closeWrite();
    });
    // Reads until the stream ends or fails, and reports which.
    b.setStreamHandler(_hold, (stream, peer) async {
      try {
        holdOutcome.complete(await _readAll(stream));
      } catch (e) {
        holdOutcome.complete(e);
      }
    });

    // Loopback listen addresses are not advertised in `addrs`.
    await a.connect(AddrInfo(b.id, b.network.listenAddresses));
    final signaling = await a.newStream(b.id, [signalingProtocol], Context());
    aConn = await initiateWebRtc(signaling);
    cleanup.add(aConn.close);
    bConn = await answered.future.timeout(const Duration(seconds: 10));
    cleanup.add(bConn.close);
  });

  tearDown(() async {
    for (final close in cleanup.reversed) {
      await close();
    }
    cleanup.clear();
  });

  test('both ends know each other and report /webrtc', () async {
    expect(aConn.remotePeer, b.id);
    expect(bConn.remotePeer, a.id);
    expect(await aConn.remotePublicKey, isNotNull);
    expect(aConn.state.streamMultiplexer, '/webrtc');
    expect(aConn.state.transport, 'webrtc');
    expect(aConn.remoteAddress, isNotNull);
  });

  test('echo protocol over a negotiated stream, with half-close', () async {
    final stream = await aConn.newProtocolStream([_echo]);
    expect(stream.protocol(), _echo);
    final data = _random(1000, 1);
    await stream.write(data);
    await stream.closeWrite();
    expect(await _readAll(stream).timeout(const Duration(seconds: 10)), data);
  });

  test("the host's own ping handler answers over WebRTC", () async {
    final stream = await aConn.newProtocolStream([_ping]);
    final payload = _random(32, 2);
    await stream.write(payload);
    final reply = BytesBuilder();
    while (reply.length < 32) {
      reply.add(await stream.read(32 - reply.length));
    }
    expect(reply.takeBytes(), payload);
    await stream.close();
  });

  test('2 MiB echo across many 16 KiB frames', () async {
    final stream = await aConn.newProtocolStream([_echo]);
    final data = _random(2 * 1024 * 1024, 3);
    final reply = _readAll(stream);
    await stream.write(data);
    await stream.closeWrite();
    expect(await reply.timeout(const Duration(seconds: 30)), data);
  });

  test('24 concurrent streams', () async {
    await Future.wait([
      for (var i = 0; i < 24; i++)
        () async {
          final stream = await aConn.newProtocolStream([_echo]);
          final data = _random(4096, 100 + i);
          await stream.write(data);
          await stream.closeWrite();
          expect(await _readAll(stream), data);
        }(),
    ]).timeout(const Duration(seconds: 30));
  });

  test('reset reaches the remote reader as a ResetException', () async {
    final stream = await aConn.newProtocolStream([_hold]);
    await stream.write(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await stream.reset();
    expect(await holdOutcome.future.timeout(const Duration(seconds: 10)), isA<ResetException>());
  });

  test('half-close delivers data then EOF to the remote', () async {
    final stream = await aConn.newProtocolStream([_hold]);
    await stream.write(Uint8List.fromList([7, 8, 9]));
    await stream.closeWrite();
    expect(await holdOutcome.future.timeout(const Duration(seconds: 10)), [7, 8, 9]);
  });

  test('unsupported protocol is refused', () async {
    expect(aConn.newProtocolStream(['/test/nope/1.0.0']), throwsA(anything));
  });

  test('the init channel is not offered as a stream', () async {
    expect(await bConn.streams, isEmpty);
  });

  test('closing one end closes the other', () async {
    await aConn.close();
    await bConn.done.timeout(const Duration(seconds: 40));
    expect(bConn.isClosed, isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
