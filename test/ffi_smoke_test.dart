// Two in-process peer connections over loopback, exercising the FFI layer:
// offer/answer, ICE, DTLS, SCTP, data channels, backpressure and teardown.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart';
import 'package:test/test.dart';

/// Host candidates on loopback only, no STUN: gathering is instant and the
/// test needs no network.
const _loopback = RtcConfig(bindAddress: '127.0.0.1');

/// Negotiates [offerer] ↔ [answerer] by passing SDP in memory.
Future<void> _connect(RtcPeerConnection offerer, RtcPeerConnection answerer) async {
  final offer = await offerer.createOffer();
  answerer.setRemoteDescription(offer, 'offer');
  final answer = await answerer.createAnswer();
  offerer.setRemoteDescription(answer, 'answer');
  await Future.wait([offerer.connected(), answerer.connected()]);
}

Uint8List _payload(int length, int seed) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

void main() {
  late RtcPeerConnection offerer;
  late RtcPeerConnection answerer;

  setUp(() {
    offerer = RtcPeerConnection(_loopback);
    answerer = RtcPeerConnection(_loopback);
  });

  tearDown(() async {
    await offerer.close();
    await answerer.close();
  });

  test('offer SDP carries an application section, fingerprint and candidates', () async {
    offerer.createDataChannel('probe');
    final sdp = await offerer.createOffer();
    expect(sdp, contains('m=application'));
    expect(sdp, contains('a=fingerprint:sha-256'));
    expect(sdp, contains('a=candidate:'));
    expect(sdp, contains('127.0.0.1'));
  });

  test('connects and echoes messages over an in-band data channel', () async {
    final local = offerer.createDataChannel('echo');
    await _connect(offerer, answerer);

    final remote = await answerer.onDataChannel.first.timeout(const Duration(seconds: 10));
    expect(remote.label, 'echo');
    remote.messages.listen(remote.send);

    await local.opened.timeout(const Duration(seconds: 10));
    expect(offerer.remoteAddress, startsWith('127.0.0.1'));

    final sizes = [0, 1, 100, 1024, 16 * 1024];
    final sent = [for (var i = 0; i < sizes.length; i++) _payload(sizes[i], i)];
    final received = local.messages.take(sent.length).toList();
    for (final message in sent) {
      await local.send(message);
    }
    expect(await received.timeout(const Duration(seconds: 10)), sent);
  });

  test('negotiated channel with a fixed stream id, no open handshake', () async {
    // libp2p /webrtc-direct runs its Noise handshake on a negotiated stream 0.
    final a = offerer.createDataChannel('', negotiated: true, stream: 0);
    final b = answerer.createDataChannel('', negotiated: true, stream: 0);
    await _connect(offerer, answerer);
    await Future.wait([a.opened, b.opened]).timeout(const Duration(seconds: 10));
    expect(a.streamId, 0);
    expect(b.streamId, 0);

    final received = b.messages.first;
    await a.send(Uint8List.fromList([1, 2, 3]));
    expect(await received.timeout(const Duration(seconds: 10)), [1, 2, 3]);
  });

  test('transfers 8 MiB in order through send backpressure', () async {
    const chunk = 16 * 1024;
    const total = 8 * 1024 * 1024;
    final local = offerer.createDataChannel('bulk');
    await _connect(offerer, answerer);
    final remote = await answerer.onDataChannel.first.timeout(const Duration(seconds: 10));
    await local.opened;

    final data = _payload(total, 42);
    final assembled = BytesBuilder(copy: false);
    final complete = Completer<void>();
    remote.messages.listen((m) {
      assembled.add(m);
      if (assembled.length >= total) complete.complete();
    });

    for (var offset = 0; offset < total; offset += chunk) {
      await local.send(Uint8List.sublistView(data, offset, offset + chunk));
      expect(local.bufferedAmount, lessThanOrEqualTo(RtcDataChannel.highWaterMark + chunk));
    }
    await complete.future.timeout(const Duration(seconds: 60));
    expect(assembled.takeBytes(), data);
  });

  test('many concurrent channels', () async {
    const count = 32;
    final locals = [for (var i = 0; i < count; i++) offerer.createDataChannel('ch$i')];
    await _connect(offerer, answerer);

    final remotes = await answerer.onDataChannel.take(count).toList().timeout(const Duration(seconds: 10));
    for (final remote in remotes) {
      remote.messages.listen(remote.send);
    }
    await Future.wait(locals.map((c) => c.opened));

    await Future.wait([
      for (var i = 0; i < count; i++)
        () async {
          final reply = locals[i].messages.first;
          final message = _payload(512, i);
          await locals[i].send(message);
          expect(await reply.timeout(const Duration(seconds: 10)), message);
        }(),
    ]);
    // Channel ids are distinct SCTP streams.
    expect(locals.map((c) => c.streamId).toSet(), hasLength(count));
  });

  test('closing a channel closes the remote end', () async {
    final local = offerer.createDataChannel('closing');
    await _connect(offerer, answerer);
    final remote = await answerer.onDataChannel.first.timeout(const Duration(seconds: 10));
    await local.opened;

    final remoteDone = remote.messages.toList();
    await local.send(Uint8List.fromList([9]));
    await local.close().timeout(const Duration(seconds: 10));
    expect(await remoteDone.timeout(const Duration(seconds: 10)), [
      [9],
    ]);
    await remote.done;
    expect(remote.isOpen, isFalse);
  });

  test('closing a peer connection ends the remote connection', () async {
    offerer.createDataChannel('x');
    await _connect(offerer, answerer);

    final ended = answerer.onStateChange
        .firstWhere((s) => s == RtcPeerState.disconnected || s == RtcPeerState.failed || s == RtcPeerState.closed);
    await offerer.close();
    expect(offerer.state, RtcPeerState.closed);
    // SCTP abort / DTLS close_notify reach the answerer quickly; ICE consent
    // expiry would take ~30 s.
    await ended.timeout(const Duration(seconds: 35));
  }, timeout: const Timeout(Duration(seconds: 45)));
}
