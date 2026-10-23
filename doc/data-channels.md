# Data channels without libp2p

Under the libp2p transport sits a plain WebRTC layer: peer connections and
data channels, with no libp2p in sight. Use it for WebRTC with your own
signaling, or to diagnose connectivity.

```dart
import 'package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart';
```

| Class | What it is |
|---|---|
| `RtcConfig` | ICE servers (STUN, TURN), relay-only mode, bind address, port range, maximum message size |
| `RtcPeerConnection` | Offer and answer, remote candidates, connection state, selected candidate pair, data channels |
| `RtcDataChannel` | Binary messages in order, with backpressure on `send` |

## Connect two peers

This program creates two peer connections in one process and passes the SDP
between them in memory. In a real program, the offer and the answer travel
over whatever signaling channel you have (a server, a relayed libp2p
stream, a QR code).

<!-- example: example/data_channel.dart#connect -->
```dart
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
```
<!-- /example -->

Our side doesn't trickle candidates: `createOffer` and `createAnswer`
complete once gathering has finished, and the SDP holds every local
candidate. That's quick with host and STUN candidates, slower when a STUN or
TURN server doesn't answer. Candidates the remote side trickles can be
added with `addRemoteCandidate`.

## Send and receive

A channel the remote side opens arrives on `onDataChannel`. Messages are
`Uint8List`s, delivered in order:

<!-- example: example/data_channel.dart#messages -->
```dart
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
```
<!-- /example -->

```sh
dart run example/data_channel.dart
```

```
connected: alice sees bob at 127.0.0.1:57019
bob got: hello
bob got: how are you?
path: a=candidate:1 1 UDP 2114977791 127.0.0.1 65198 typ host <-> a=candidate:1 1 UDP 0 127.0.0.1 57019 typ prflx
```

## Details

- **Backpressure.** `send` waits while more than 1 MiB is buffered, and
  resumes when the buffer drains below 256 KiB. Await it in a loop and a
  fast sender can't run away from a slow network.
- **Channel options.** `createDataChannel(label, negotiated: true, stream: n)`
  creates a pre-negotiated channel with a fixed stream ID and no in-band
  open handshake, as libp2p's `/webrtc-direct` uses for its Noise
  handshake.
- **State.** `onStateChange` reports `connecting`, `connected`,
  `disconnected`, `failed` and `closed`; `connected()` completes when the
  connection is up, or throws if it fails or times out.
- **Closing.** `RtcDataChannel.close()` closes one channel (the remote sees
  its stream end); `RtcPeerConnection.close()` closes everything.
- **Logging.** `RtcRuntime.enableNativeLogging(RtcLogLevel.debug)` prints
  libdatachannel's own log to stdout. The Dart side logs through
  `package:logging` (loggers `WebRtcConn`, `WebRtcStream`, `WebRtcTransport`,
  `WebRtcSignaling`).
