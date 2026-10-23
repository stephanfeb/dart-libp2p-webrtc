// The TURN fallback at the FFI layer: peer connections that may only use
// relay candidates, through coturn (docker/coturn/compose.yaml, or TURN_URL).
@Tags(['turn'])
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart';
import 'package:test/test.dart';

import 'turn_server.dart';

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
  String? skip;
  final pcs = <RtcPeerConnection>[];

  setUpAll(() async => skip = await turnUnavailable());

  tearDown(() async {
    for (final pc in pcs) {
      await pc.close();
    }
    pcs.clear();
  });

  RtcPeerConnection pc(RtcConfig config) {
    final created = RtcPeerConnection(config);
    pcs.add(created);
    return created;
  }

  // Both sides relay-only: libdatachannel's relay policy only filters the
  // candidates it advertises (see RtcConfig.relayOnly), so one relay-only
  // side alone can still end up on a direct path.
  test('relay-only peers connect through TURN and echo 1 MiB', () async {
    if (skip != null) return markTestSkipped(skip!);
    final offerer = pc(RtcConfig(iceServers: [turnUrl], relayOnly: true));
    final answerer = pc(RtcConfig(iceServers: [turnUrl], relayOnly: true));
    final local = offerer.createDataChannel('echo');

    final offer = await offerer.createOffer();
    expect(RegExp(r'a=candidate:.* typ (\w+)').allMatches(offer).map((m) => m.group(1)).toSet(), {'relay'},
        reason: 'a relay-only offer has only relay candidates');
    await _connect(offerer, answerer).timeout(const Duration(seconds: 30));

    final pair = offerer.selectedCandidatePair!;
    expect(pair.local, contains('typ relay'));
    expect(pair.remote, contains('typ relay'));

    final remote = await answerer.onDataChannel.first.timeout(const Duration(seconds: 10));
    remote.messages.listen(remote.send);
    await local.opened.timeout(const Duration(seconds: 10));
    final sent = [for (var i = 0; i < 64; i++) _payload(16 * 1024, i)];
    final received = local.messages.take(sent.length).toList();
    for (final message in sent) {
      await local.send(message);
    }
    expect(await received.timeout(const Duration(seconds: 20)), sent);
  });

  test('wrong credentials give no relay candidates', () async {
    if (skip != null) return markTestSkipped(skip!);
    final badUrl = turnUrl.replaceFirst(RegExp(r'turn:[^@]+@'), 'turn:test:wrong@');
    final offerer = pc(RtcConfig(iceServers: [badUrl], relayOnly: true));
    offerer.createDataChannel('probe');
    final offer = await offerer.createOffer().timeout(const Duration(seconds: 30));
    expect(offer, isNot(contains('typ relay')));
  });
}
