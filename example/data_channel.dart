// WebRTC data channels without libp2p: two peer connections in one process,
// with the SDP passed between them in memory. In a real program the offer
// and answer travel over whatever signaling channel you have.
//
//   dart run example/data_channel.dart
import 'dart:convert';

import 'package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart';

Future<void> main() async {
  // #region connect
  // Host candidates on loopback only, so this runs without a network. Pass
  // STUN (and TURN) servers in iceServers for peers on different networks.
  const config = RtcConfig(bindAddress: '127.0.0.1');
  final alice = RtcPeerConnection(config);
  final bob = RtcPeerConnection(config);

  // The offer needs a data channel to have an application section.
  final chat = alice.createDataChannel('chat');

  // createOffer and createAnswer wait for ICE gathering, so each SDP carries
  // all of its side's candidates.
  final offer = await alice.createOffer();
  bob.setRemoteDescription(offer, 'offer');
  final answer = await bob.createAnswer();
  alice.setRemoteDescription(answer, 'answer');
  await Future.wait([alice.connected(), bob.connected()]);
  print('connected: alice sees bob at ${alice.remoteAddress}');
  // #endregion connect

  // #region messages
  // Bob answers every message on the channel Alice opened.
  final bobChat = await bob.onDataChannel.first;
  bobChat.messages.listen((message) {
    bobChat.send(utf8.encode('bob got: ${utf8.decode(message)}'));
  });

  await chat.opened;
  final replies = chat.messages.take(2).map(utf8.decode).toList();
  // send() completes when the message is queued; it waits while the
  // channel's buffer is full, which is how backpressure reaches the caller.
  await chat.send(utf8.encode('hello'));
  await chat.send(utf8.encode('how are you?'));
  for (final reply in await replies) {
    print(reply);
  }
  // #endregion messages

  final pair = alice.selectedCandidatePair;
  print('path: ${pair?.local} <-> ${pair?.remote}');
  await alice.close();
  await bob.close();
}
