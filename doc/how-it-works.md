# How it works

This page follows a connection from the relay to the native library. You
don't need it to use the package; it helps when something goes wrong.

## Addresses

A peer that accepts WebRTC connections listens on `/webrtc` and has a
reservation on a relay. Peers reach it at:

```
<relay address>/p2p/<relay id>/p2p-circuit/webrtc/p2p/<peer id>
```

`WebRtcTransport.canDial` accepts addresses where `/webrtc` directly follows
`/p2p-circuit`. dart_libp2p's own circuit transport doesn't take them, so the
order of transports doesn't decide which one dials (still, add the WebRTC
transport first). With AutoRelay, a host listening on `/webrtc` also
advertises each relay address with `/webrtc` appended.

Once connected, a WebRTC connection's remote address is the peer's selected
ICE candidate followed by `/webrtc`, e.g. `/ip4/203.0.113.7/udp/52011/webrtc`.
It never contains `/p2p-circuit`, because dart_libp2p treats any
`/p2p-circuit` address as relayed.

## Signaling

The dialer needs a relayed connection to the peer. Over it, the dialer opens
a `/webrtc-signaling/0.0.1` stream and the two sides exchange varint-prefixed
protobuf messages ([spec](https://github.com/libp2p/specs/blob/master/webrtc/webrtc.md)):

1. The dialer creates a data channel labelled `init` (so the offer has an
   application section) and sends an `SDP_OFFER`.
2. The listener answers with an `SDP_ANSWER`.
3. Each side sends `ICE_CANDIDATE` messages as it finds candidates; the
   browser trickles them. Our side puts every candidate in its SDP instead
   (it waits for gathering), and applies the remote's candidates as they
   arrive.
4. When ICE connects, the dialer closes `init` and both close the signaling
   stream.

There is no extra handshake: the relayed connection is already
authenticated (Noise), so the peer IDs on either end of the signaling stream
are the peer IDs of the WebRTC connection. The DTLS certificates aren't tied
to peer IDs, as the spec intends for `/webrtc`.

## Streams

Each libp2p stream is a WebRTC data channel, negotiated in-band, with an
empty label. Data channels are message-based and have no half-close, so the
spec frames every message:

```
varint length | protobuf Message { flag?: FIN | STOP_SENDING | RESET_STREAM | FIN_ACK, message?: bytes }
```

A frame is at most 16 KiB. `closeWrite` sends `FIN` and waits up to
10 seconds for `FIN_ACK`; `closeRead` sends `STOP_SENDING`; `reset` sends
`RESET_STREAM`. Frames can span data-channel messages, so the reader parses
a byte stream rather than one frame per message.

## The swarm

dart_libp2p's swarm normally runs every new connection through the
upgrader, which negotiates Noise and Yamux. A WebRTC connection is already
encrypted (DTLS) and multiplexed (data channels), so `WebRtcConn` implements
`UpgradedTransportConn` (dart_libp2p 4.9.0), and the swarm adopts it as it
is. It reports `/webrtc` as its multiplexer, as js-libp2p does.

`WebRtcTransport.upgrade(peer)` adds the relay's `/p2p-circuit/webrtc`
address for the peer to the peerstore and dials with `forceDirectDial`, as
a hole punch does. The transport doesn't open the relayed connection
itself: the swarm joins concurrent dials to the same peer, so a WebRTC dial
waiting on a relay dial to the same peer would wait on itself.

## The native layer

libdatachannel v0.24.6 is built for data channels only: no media, no
WebSocket, DTLS through Mbed TLS 3.6.7. libjuice does ICE and usrsctp does
SCTP. The package's build hook runs CMake and Ninja for the target and
links everything into one shared library.

Callbacks from native threads reach Dart through
`NativeCallable.listener`, which runs them later on the Dart event loop. By
then, pointers the callback received are no longer valid. So callbacks
carry only IDs and states, and the Dart side pulls data synchronously:
`rtcGetLocalDescription` once gathering is done, `rtcReceiveMessage` when a
channel reports data available. No native pointer outlives a callback.

The isolate is kept alive only while peer connections or channels exist.
