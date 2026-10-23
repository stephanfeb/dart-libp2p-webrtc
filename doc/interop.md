# Interoperability

What this package is tested against, and how the tests run. The tests live
in the repository, not in the published package: they drive real browsers
and start relays written in other languages.

## Tested against

| Peer | Versions | Directions |
|---|---|---|
| js-libp2p in Chrome | js-libp2p 3.5, Chrome 156 | browser → Dart and Dart → browser |
| js-libp2p in Firefox | js-libp2p 3.5, Firefox 157 | both |
| js-libp2p in WebKit | js-libp2p 3.5, WebKit 27 | both |
| dart_libp2p | 4.9 | both |

| Relay | Notes |
|---|---|
| js-libp2p circuit relay v2 | No relay limits |
| go-libp2p circuit relay v2 | Default limits (2 min, 128 KiB), so relayed connections are limited |
| dart_libp2p circuit relay v2 | |
| go-ricochet (go-libp2p) on the internet | UDX for Dart, WSS for browsers |

Over each connection the tests run identify, ping, a 1 KiB echo, a 1 MiB
echo and 16 concurrent streams.

## Devices and networks

| Device | Network | Result |
|---|---|---|
| macOS | loopback, LAN | all checks |
| Linux (Docker) | loopback | the WebRTC layer (data channels between two peer connections) |
| Pixel 10a, Android 17 | Wi-Fi | all checks, all four directions (Dart ↔ phone, browser ↔ phone) |
| iPhone 15, iOS 26 | Wi-Fi | all checks, all four directions |
| iPhone 15, iOS 26 | cellular, via the public relay, browser and Dart host on home Wi-Fi with IPv6 | all checks, all four directions, direct over IPv6 |
| iPhone 15, iOS 26 | cellular IPv4 (symmetric NAT) to an IPv4-only network | no direct path; needs TURN ([Networks](networks.md)) |

TURN is tested with coturn: relay-only peers connect relay to relay, and a
relay-only browser (strict `iceTransportPolicy: 'relay'`) connects to a Dart
host in both directions, in Chrome and WebKit.

## How the tests work

- **Browsers.** A Playwright driver loads a js-libp2p page bundled with
  esbuild; the page reports results as console lines that the Dart test
  reads. The same page is the source of the browser code in
  [Browsers](browsers.md).
- **Relays.** The tests start a js-libp2p relay (Node.js) and a go-libp2p
  relay (a small Go program) as separate processes.
- **Phones.** A Flutter app runs a session against a desktop hub: a relay,
  a Dart host and a headless browser. The hub dials the phone, then the
  phone dials the hub's Dart host and browser. Over a public relay, the
  phone starts the session over libp2p, so it works from any network.
- **Examples.** The test suite runs the programs in `example/` and checks
  that every code sample in these guides matches them.

Running them needs Node.js 22 (for js-libp2p 3), Playwright's browsers, Go,
and Docker for TURN; each group skips when its tools are missing.
