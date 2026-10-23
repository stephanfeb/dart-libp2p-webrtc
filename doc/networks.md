# Networks

A WebRTC connection is direct when ICE finds a path between the two peers.
Whether it can depends on the networks they're on. This page covers what to
configure, what to expect on common networks, and the fallbacks.

## ICE servers

Pass STUN and TURN servers in `RtcConfig.iceServers`:

```dart
WebRtcTransport(
  rtcConfig: const RtcConfig(iceServers: [
    'stun:stun.l.google.com:19302',
    'stun:stun.cloudflare.com:3478',
    'turn:user:password@turn.example.com:3478',
  ]),
)
```

- **STUN** tells a peer its public address, so peers behind NAT can find a
  path. Free public STUN servers are fine; js-libp2p uses some by default.
- **TURN** relays the traffic when no direct path exists. TURN servers
  carry real traffic, so you run one ([Running a TURN server](turn.md)) or
  pay for a hosted one. The URL is `turn:<user>:<password>@<host>:<port>`,
  with the user and password percent-encoded.

Give the browser the same TURN server, in js-libp2p's
`webRTC({ rtcConfiguration: { iceServers: [...] } })`.

ICE prefers direct paths and uses TURN only when they fail, so adding TURN
doesn't slow down peers that can connect directly.

## What connects directly

| Situation | Direct? |
|---|---|
| Same network | Yes (host candidates; on iOS, see [Flutter and mobile](flutter.md#permissions)) |
| Both peers have IPv6 | Yes: IPv6 is usually not NATed, including on carrier networks |
| Cone NAT on both sides (most home routers) | Yes, with STUN |
| Symmetric NAT on one side (common on carrier IPv4), and no IPv6 path | **Usually not**: plan for TURN |
| A network that blocks UDP | **No**, and TURN doesn't help on the Dart side (see below) |

Measured, with a phone on a carrier network whose IPv4 NAT is symmetric:

| Phone network | Other side | Result |
|---|---|---|
| Cellular, IPv4 only | Browser on IPv4-only home Wi-Fi | No direct path: all 7 raw WebRTC scenarios failed without TURN |
| Cellular, IPv6 | Browser and Dart host on home Wi-Fi with IPv6 | Direct over IPv6, in both directions; the browser dialed the phone in about 1.1 s |

## TURN on the Dart side: UDP only

libdatachannel uses libjuice for ICE, and libjuice supports **TURN over UDP
only**. TURN over TCP and over TLS (`turns:`, port 443) aren't available to
Dart peers, although browsers support them.

So on a network that blocks UDP entirely (some corporate and hotel Wi-Fi),
a Dart peer can't make WebRTC connections at all. Keep using the relayed
libp2p connection in that case: it runs over TCP to the relay, within the
relay's limits.

## Relay-only mode

`RtcConfig(relayOnly: true)` advertises only TURN relay candidates. Unlike a
browser's `iceTransportPolicy: 'relay'`, it doesn't stop ICE from using
host sockets: libdatachannel only leaves the other candidates out of the
SDP, so if the remote side sends host candidates, a direct path can still
win. Use it to test TURN (set it on both sides), not as a privacy
guarantee.

## Which path did it take?

`WebRtcConn.selectedCandidatePair` returns the selected candidate pair, as
SDP `candidate:` lines. `typ relay` on either side means TURN carries the
connection; `typ host`, `srflx` or `prflx` means it's direct.

```dart
final conn = await webrtc.upgrade(peer) as SwarmConn;
print((conn.conn as WebRtcConn).selectedCandidatePair);
```

## When WebRTC can't connect

`upgrade` throws when ICE doesn't connect within the signaling timeout
(30 seconds by default, `WebRtcTransport(signalingTimeout: …)`). The relayed
connection stays up, so the peers can keep talking through the relay. Keep
in mind that relays limit relayed connections: go-libp2p's defaults are
2 minutes and 128 KiB per connection, and dart_libp2p reports such a
connection as limited (`conn.stat.stats.limited`).
