# dart_libp2p_webrtc

The libp2p **WebRTC transport** (`/webrtc`, "private-to-private") for
[dart-libp2p](https://pub.dev/packages/dart_libp2p). Dart and Flutter apps,
and web apps running [js-libp2p](https://github.com/libp2p/js-libp2p) in a
browser, connect **directly** to each other: they find each other through
a libp2p circuit relay, exchange SDP over it, and then talk peer to peer
over WebRTC data channels.

It implements the [libp2p WebRTC spec](https://github.com/libp2p/specs/blob/master/webrtc/webrtc.md)
on top of [libdatachannel](https://github.com/paullouisageneau/libdatachannel),
a C/C++ WebRTC library, through `dart:ffi`. The native library is built from
source by the package's build hook, so there's nothing to install
separately.

```
 browser (js-libp2p)              relay (go/js/dart-libp2p)            phone (dart-libp2p)
        │  WSS ─────────────────────── reservation ─────────────────── UDX/TCP  │
        │  /webrtc-signaling/0.0.1: SDP offer/answer, ICE candidates           │
        └──────────────── direct WebRTC (DTLS, SCTP data channels) ─────────────┘
```

**Documentation:** guides for getting started, browsers, Flutter and mobile,
networks (STUN, TURN, NAT) and the internals are at
[cryptopeer.net/libp2p/webrtc](https://cryptopeer.net/libp2p/webrtc/), from
this repository's [`doc/`](doc/index.md).

## Status

0.1.0: the first release. Tested:

- **Browsers:** js-libp2p 3.x in Chrome, Firefox and WebKit, dialing and
  being dialed by dart-libp2p hosts.
- **Relays:** js-libp2p, go-libp2p (with its default limits) and dart-libp2p
  circuit relays, and a production go-libp2p relay over the internet.
- **Devices:** macOS and Linux hosts, an Android phone (Pixel, Android 17)
  and an iPhone (iOS 26) on Wi-Fi, and the iPhone on a cellular network
  talking to a browser elsewhere.
- **NAT traversal:** STUN, and TURN for networks where no direct path
  exists (see [Networks](#networks-stun-turn-and-what-to-expect)).

## Requirements

| | |
|---|---|
| Dart | 3.10 or later (Flutter 3.38 or later) |
| dart_libp2p | 4.9.0 or later |
| Platforms | Android, iOS, Linux, macOS. Not Windows or the web: in a browser, use js-libp2p's own WebRTC transport. |
| Build tools | **CMake** (3.21 or later) and **Ninja** on `PATH`, and a C/C++ toolchain: Xcode on Apple platforms, the Android NDK for Android, GCC or Clang on Linux. |

The first build compiles libdatachannel and Mbed TLS (a few minutes); later
builds are cached. The resulting library is about 3 to 4 MB per ABI.

```sh
dart pub add dart_libp2p_webrtc
# Flutter: flutter pub add dart_libp2p_webrtc
```

## Usage

### A host that accepts WebRTC connections

Add the transport **before** the other transports (the swarm uses the first
one that can dial an address), listen on `/webrtc`, and attach it to the
host before starting it:

```dart
import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p_webrtc/libp2p.dart';

final connManager = ConnectionManager();
final webrtc = WebRtcTransport(
  rtcConfig: const RtcConfig(iceServers: ['stun:stun.l.google.com:19302']),
);
final host = await Libp2p.new_([
  Libp2p.connManager(connManager),
  Libp2p.transport(webrtc),
  Libp2p.transport(TCPTransport(connManager: connManager)), // or UDX, to reach the relay
  Libp2p.listenAddrs([MultiAddr('/webrtc')]),
  Libp2p.relay(true),
]);
webrtc.attach(host);
await host.start();
```

Then book a reservation on a circuit relay, as for any relayed host (or
enable AutoRelay):

```dart
final relay = AddrInfo.fromMultiaddr(MultiAddr('/ip4/…/tcp/…/p2p/<relay-id>'));
await host.connect(relay);
await (host as BasicHost).circuitV2Client!.reserve(relay.id);
```

The host is now reachable over WebRTC at
`<relay address>/p2p-circuit/webrtc/p2p/<host id>`. With AutoRelay, the host
advertises those addresses itself.

Incoming WebRTC connections join the host's swarm like any other
connection: your stream handlers serve them, and identify, ping and your
protocols work over them unchanged.

### Dialing a peer over WebRTC

The dialer needs a relayed connection to the peer first. WebRTC's signaling
runs over it.

```dart
await host.connect(relay); // the circuit client needs to know the relay
await host.connect(AddrInfo(peer, [MultiAddr('$relayAddr/p2p-circuit')]));
final conn = await webrtc.upgrade(peer); // direct from here on
```

`upgrade` adds the relay's `/p2p-circuit/webrtc` address for the peer and
dials past the relayed connection, as a hole punch does. New streams to the
peer then prefer the direct connection. The swarm dials every direct address
it knows for the peer, so if the peer also has a reachable TCP or UDX address,
that connection may win instead; the returned `Conn` tells you which.

A complete program is in [example/example.dart](example/example.dart).

### The browser side (js-libp2p)

```js
import { createLibp2p } from 'libp2p'
import { webRTC } from '@libp2p/webrtc'
import { webSockets } from '@libp2p/websockets'
import { circuitRelayTransport } from '@libp2p/circuit-relay-v2'
import { noise } from '@chainsafe/libp2p-noise'
import { yamux } from '@chainsafe/libp2p-yamux'
import { identify } from '@libp2p/identify'
import { multiaddr, registry } from '@multiformats/multiaddr'

// Relays that also speak UDX (go-ricochet, dart-libp2p) list /udx addresses
// in their reservations; without this codec js-libp2p rejects the whole
// reservation ("Protocol 768 was unknown").
registry.addProtocol({ code: 0x0300, name: 'udx', size: 0 })

const node = await createLibp2p({
  addresses: { listen: ['/dns4/relay.example.com/tcp/443/wss/p2p/<relay-id>/p2p-circuit', '/webrtc'] },
  transports: [webSockets(), webRTC(), circuitRelayTransport()],
  connectionEncrypters: [noise()],
  streamMuxers: [yamux()],
  services: { identify: identify() }
})

// Dial a Dart host that has a reservation on the same relay.
const conn = await node.dial(multiaddr('/dns4/relay.example.com/tcp/443/wss/p2p/<relay-id>/p2p-circuit/webrtc/p2p/<dart-host-id>'))
```

Browsers reach relays over WebSockets. Pages served over HTTPS need the
relay's **WSS** address: browsers block plain `ws://` from secure pages.

### Relays

Any libp2p circuit relay v2 works: go-libp2p, js-libp2p or dart-libp2p. The
relay only carries signaling (an SDP offer and answer and a few ICE
candidates, a few KB), so the default go-libp2p limits (2 minutes, 128 KiB
per relayed connection) are plenty. To serve both browsers and Dart hosts,
the relay needs a WebSocket listener (with TLS for HTTPS pages) as well as
TCP or UDX. dart-libp2p has no WebSocket transport, so Dart hosts reach
relays over TCP or UDX.

## Networks: STUN, TURN and what to expect

WebRTC connects directly when ICE finds a path. Pass STUN servers in
`RtcConfig.iceServers` so hosts behind NAT learn their public addresses.

- **IPv6 on both ends:** connects directly, including phone (cellular) ↔
  browser (home), since carrier IPv6 is usually not NATed.
- **Cone NATs (most home routers):** connects directly via STUN.
- **A symmetric NAT on either end** (common on carrier IPv4) **with no IPv6
  path:** no direct path exists. You need a **TURN** server: add
  `turn:user:pass@host:3478` to `iceServers` on the Dart side and the same
  server to the browser's `rtcConfiguration`. ICE uses the relay only when
  direct paths fail.

TURN limits on the Dart side: libdatachannel's ICE library (libjuice)
supports **TURN over UDP only**, not TCP or TLS (`turns:`). On networks that
block UDP entirely, Dart hosts can't make WebRTC connections. Keep using the
relayed libp2p connection there.

`RtcConfig.relayOnly` advertises only relay candidates. Unlike a browser's
`iceTransportPolicy: 'relay'`, it doesn't stop ICE from using host sockets
when the other side sends host candidates, so it's a testing aid, not a
privacy guarantee.

## Lower-level API

`package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart` exposes the FFI layer
without libp2p: `RtcPeerConnection` (offer/answer, remote candidates, state,
selected candidate pair) and `RtcDataChannel` (binary messages with
backpressure). It's useful for WebRTC data channels outside libp2p, and for
diagnostics.

`package:dart_libp2p_webrtc/libp2p.dart` also exports the pieces of the
transport: `initiateWebRtc` / `answerWebRtc` (run the signaling protocol
over any authenticated stream), `WebRtcConn` and `WebRtcStream`.

## How it works

- **Signaling** (`/webrtc-signaling/0.0.1`): the dialer opens the stream over
  the relayed connection, sends an SDP offer with all its candidates (no
  trickle on our side), and applies the remote's trickled candidates until
  ICE connects. The relayed connection is authenticated (Noise), so the
  WebRTC connection inherits the peer identities; the spec has no extra
  handshake.
- **Streams** are data channels negotiated in-band, with the spec's
  length-prefixed protobuf framing and FIN, FIN_ACK, STOP_SENDING and
  RESET_STREAM, so half-close works as on any libp2p stream.
- **The swarm** adopts these connections without running its upgrader
  (dart_libp2p 4.9.0's `UpgradedTransportConn`); they report `/webrtc` as
  their muxer, as js-libp2p does.
- **Native:** libdatachannel v0.24.6 built for data channels only (no media,
  no WebSocket), DTLS 1.2 through Mbed TLS 3.6.7, linked into one shared
  library per platform. Callbacks only carry ids; data is pulled
  synchronously, so no native pointers outlive a callback.

## Limitations

- TURN over UDP only on the Dart side (see above).
- Our side doesn't trickle ICE candidates; the offer or answer waits for
  gathering to finish (fast with host and STUN candidates, slower with
  unreachable STUN servers).
- No automatic upgrade: call `WebRtcTransport.upgrade` when you want a
  direct connection to a relayed peer.
- No `/webrtc-direct` (browser to a public server without a relay).
- Not available on Windows.

## Development

The repository (not the published package) also has interop tests against
js-libp2p in real browsers via Playwright, go-libp2p relays, a coturn TURN
setup in Docker, and a Flutter app that runs the same sessions on phones.
See `DESIGN.md` in the repository for the design and the test results.

## License

MIT; see [LICENSE](LICENSE). The bundled native sources keep their own
licenses (MPL-2.0, Apache-2.0, BSD-3-Clause, MIT); see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
