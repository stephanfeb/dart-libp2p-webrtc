# Changelog

## 0.1.0

First release.

- libp2p `/webrtc` (private-to-private, per the libp2p WebRTC spec) for
  dart-libp2p: `WebRtcTransport` dials and accepts connections signaled over
  `/webrtc-signaling/0.0.1` on a circuit-relay connection; `upgrade(peer)`
  moves a relayed peer onto a direct WebRTC connection. Connections join the
  dart-libp2p swarm (needs dart_libp2p 4.9.0), streams are data channels
  with the libp2p WebRTC framing (FIN / FIN_ACK / STOP_SENDING / RESET).
- Interoperates with js-libp2p 3.x in Chrome, Firefox and WebKit, both
  ways, through js-libp2p, go-libp2p and dart-libp2p relays.
- Native: libdatachannel v0.24.6 (data channels only) with Mbed TLS 3.6.7,
  built from source by the package's build hook for Android, iOS, Linux
  and macOS. Needs CMake and Ninja.
- FFI layer (`package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart`):
  `RtcPeerConnection`, `RtcDataChannel`, `RtcConfig` (STUN/TURN servers,
  `relayOnly`), selected candidate pair.
- Known limits: TURN over UDP only (libjuice); `RtcConfig.relayOnly` only
  filters advertised candidates; no trickle of our own candidates; no
  automatic upgrade of relayed peers.
