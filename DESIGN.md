# dart_libp2p_webrtc — libdatachannel FFI transport design

Status: sketch · 2026-10-23

## Goal

Browser (js-libp2p) ↔ phone (dart-libp2p) direct connectivity using the libp2p
**`/webrtc` (private-to-private)** transport. libdatachannel supplies ICE, DTLS,
SCTP and DCEP; this package supplies the libp2p layer on top.

Non-goals for v1: `/webrtc-direct` listening, media, a pure-Dart stack (kept
possible by hiding libdatachannel behind a thin wrapper — see §4).

## Status (2026-10-23)

FFI layer done and proven against real browsers (`test/interop/`), with
libdatachannel v0.24.6 + Mbed TLS 3.6.7 on macOS arm64:

| Browser | Result | DTLS |
|---|---|---|
| Chrome 156 | 7/7 | 1.2, ECDHE-ECDSA-CHACHA20-POLY1305 |
| Firefox 157 (Playwright) | 7/7 | 1.2, ECDHE-ECDSA-AES128-GCM |
| WebKit 27.2 (Playwright) | 7/7 | 1.2, ECDHE-ECDSA-CHACHA20-POLY1305 |

On phones (example/interop_app, Dart peer on the phone, Chrome 156 on the
desktop, same Wi-Fi, debug builds): iPhone (iOS 26.6.1) 7/7, Pixel 10a
(Android 17) 7/7.

Scenarios: either side offering, pre-negotiated stream 0, 4 MiB each way,
16 concurrent channels, channel close. All browsers sent only mDNS `.local`
host candidates; libdatachannel connected anyway. Not yet tested: the libp2p
layer (§3).

**Cellular NAT test (iPhone on cellular, Chrome behind a home router, STUN
both sides): 0/7 — ICE never connected.** Both sides gathered correct
candidates; only IPv4 srflx↔srflx was possible (home network has no IPv6).
The phone's carrier NAT mapped the same local port to a different public port
each session and never preserved it (consistent with symmetric CGNAT); the home
router preserved ports (likely port-restricted filtering). That pairing cannot
be hole-punched without a relay, so production needs a fallback: TURN, or
staying on a libp2p circuit relay with relaxed limits (§6).

NAT check (`tool/nat_check.dart`, app "Check NAT", 3 STUN operators) confirmed
it: the carrier's IPv4 is **address-dependent ("symmetric")**, a different public
port per server; the home router is endpoint-independent with port
preservation. The carrier's **IPv6 has no NAT** (servers see the phone's own
address and port), so a browser peer with IPv6 should connect directly; the
test home network has no IPv6, which ruled that path out. Untethered runs need
release builds: iOS kills debug (JIT) builds once the debugger detaches.

### libp2p layer, phase A (2026-10-23)

Built in this repo against the published `dart_libp2p` 4.8.1 (no changes to
dart-libp2p or dart-udx): `/webrtc-signaling/0.0.1` both roles
(`initiateWebRtc`, `answerWebRtc`), stream framing (`WebRtcStream`), and
`WebRtcConn` (streams = data channels). Until the swarm can adopt
pre-upgraded connections (phase B, §4), a `WebRtcConn` serves the host's
protocols itself via `serveStreams(host.mux)`.

**js-libp2p 3.5.1 in a browser dials a Dart host at
`<relay ws>/p2p-circuit/webrtc/p2p/<dart>`** (`test/interop/js_libp2p_interop_test.dart`,
js relay over WebSockets, Dart host over TCP): connection is `/webrtc`,
native encryption, not limited; identify, ping, 1 MiB echo and 16 concurrent
streams pass on Chrome 156, Firefox 157 and WebKit 27.2. Needs Node 22+
(`NODE=…`); skipped otherwise.

Corrections to §3 from the spec and js-libp2p 7.0.2: the offerer's channel is
labelled `init` and closed once connected; ICE candidates are trickled as
`RTCIceCandidate.toJSON()`; the signaling `type` field must always be
encoded (js rejects an absent SDP_OFFER); frames are parsed from a byte
stream (they may span data-channel messages).

### libp2p layer, phase B (2026-10-23)

dart-libp2p core changes are on its `main` (commit bf1539a, not yet
released; this repo uses the sibling checkout through `pubspec_overrides.yaml`,
while dart_udx still comes from pub.dev). See §4 for what landed.

`WebRtcTransport` (+ listener on bare `/webrtc`) plugs into the swarm:
`attach(host)` before `start()`; inbound signaling becomes swarm
connections through the listener; `dial` needs an existing relayed
connection and signals over it; `upgrade(peer)` adds the relay's
`/p2p-circuit/webrtc` address to the peerstore and dials with
`forceDirectDial`, as DCUtR does. (A dial that obtained its own relayed
connection would join the swarm's in-progress dial to the same peer and
deadlock.) `WebRtcConn.remoteMultiaddr` is the selected candidate
(`/ip4/…/udp/…/webrtc`), never a `/p2p-circuit` address, because the swarm
treats those as relayed.

Results: Dart↔Dart through a Dart relay (`test/libp2p/webrtc_transport_test.dart`,
4 tests: both swarms adopt the connection, host streams prefer it both ways,
300 KiB echo, 16 streams, ping). js-libp2p interop now runs through the
swarm in **both directions**: the browser dials Dart, and Dart dials a
browser listening on `/webrtc` (1 MiB echo and ping), on Chrome, Firefox and
WebKit. A browser closing its connection now reaches the Dart swarm.

### go-libp2p interop (2026-10-23)

go-libp2p (v0.49) has no `/webrtc` (private-to-private) transport, only
`/webrtc-direct`, so there is no Go WebRTC peer to test against. What go
contributes is the relay: `interop/go/relay` is a go-libp2p circuit relay v2
with the default limits (2 min, 128 KiB per relayed connection), the same
defaults go-ricochet ships. Both suites now run through it as well as
through the js (or Dart) relay: Dart↔Dart (`webrtc_transport_test.dart`)
and browser↔Dart in both directions (`js_libp2p_interop_test.dart`) pass on
Chrome, Firefox and WebKit, so signaling works over limited relayed
connections. Needs Go; the go groups are skipped without it.

Fixed on the way (dart-libp2p main, commit 71caf58): a relayed
connection (`RelayedConn`) always reported `limited: false`. It now reports
whether the relay sent a limit in HOP STATUS (dialer) or STOP CONNECT
(listener), as go-libp2p does. Through the go relay both sides report
limited; through the js test relay (no default limit) and the Dart relay
(which sends no per-connection limit) neither does. Nothing in dart-libp2p
acts on the flag yet. (`CircuitConnection`, which hardcodes `false`, is
unused.)

### TURN fallback (2026-10-23)

For networks where no direct path exists (the carrier's symmetric IPv4 NAT),
WebRTC falls back to a TURN relay: put `turn:user:pass@host:port` (TURN over
UDP; libjuice) in `RtcConfig.iceServers`, e.g.
`WebRtcTransport(rtcConfig: RtcConfig(iceServers: [...]))`, and ICE uses the
relay only when direct candidates fail. `RtcConfig.relayOnly` and
`RtcPeerConnection.selectedCandidatePair` / `WebRtcConn.selectedCandidatePair`
were added for testing and diagnostics.

Caveat: libdatachannel's relay policy only leaves non-relay candidates out
of the SDP (`peerconnection.cpp:1100`); libjuice still runs checks from host
sockets, so one relay-only Dart side can still connect directly. Browsers'
`iceTransportPolicy: 'relay'` is strict.

Tests use coturn in Docker (`docker/coturn/compose.yaml`, user test/test,
relay ports 49160-49200; tag `turn`, skipped when nothing answers on 3478,
or `TURN_URL` for another server):
- FFI: two relay-only peers connect relay↔relay and echo 1 MiB; wrong
  credentials give no relay candidates (`test/turn_test.dart`).
- libp2p Dart↔Dart, both transports relay-only, signaling through the go
  relay: relay↔relay WebRTC, all protocol tests incl. 300 KiB echoes both
  ways (more than the go relay's 128 KiB limit).
- js-libp2p: the browser relay-only (strict), the Dart host with TURN as a
  plain fallback: browser→Dart and Dart→browser, all protocol tests, Dart
  sees the browser's relay candidate. Passes on Chrome and WebKit; skipped on
  Firefox, which will not use a TURN server on loopback.

Local-setup notes: TURN is on loopback on purpose. Docker Desktop (macOS)
has no host networking here, so a relay's traffic to a peer on the Mac
leaves through Docker's NAT with rewritten ports; with TURN on the LAN
address, browsers handled that unevenly (WebKit timed out, Firefox could
not be dialed). On loopback both peers allocate on coturn, which relays
between its own allocations. A browser may still label its local candidate
`prflx` (the NAT-mapped address of its relay), which the test allows.
Not yet tested: a real TURN deployment over cellular (the actual target).

### Phones on the full libp2p stack (2026-10-23)

`tool/libp2p_hub.dart` (desktop: go relay on the LAN, a Dart host, headless
Chrome) and the app's "libp2p over WebRTC" section
(`lib/src/interop/libp2p_phone.dart`) run a session per phone in four
directions: Dart → phone, browser → phone, phone → Dart, phone → browser;
each is relayed connect, WebRTC upgrade, ping, 1 KiB / 1 MiB echo and 16
concurrent streams. `test/interop/libp2p_hub_test.dart` runs the same on
the desktop. Test hosts listen on `/webrtc` only, so on a shared LAN an
upgrade cannot end on a direct TCP connection instead.

Wi-Fi results: Pixel 10a (Android 17) 25/25 and iPhone (iOS 26.6) 25/25,
host↔host paths, pings 6–21 ms, 1 MiB round trips at 4–6 MB/s.

Fixed on the way: the iOS library failed to load because it linked Mbed
TLS's everest and p256m as separate dylibs that were never bundled.
`BUILD_SHARED_LIBS` was a forced cache variable, so a re-configured build
directory built them shared; it is now a plain variable per subproject.
`test/native_library_test.dart` checks (macOS) that the library links only
system libraries.

Open: with the iPhone on Wi-Fi, one Dart → phone connection reported the
phone's cellular IPv6 address as its remote while the Mac had no IPv6;
unexplained (likely what libdatachannel reports, not the path used).
Off-LAN: see "In the wild through go-ricochet" below.

### In the wild through go-ricochet (2026-10-23)

The public go-ricochet relay (go-libp2p, default relay limits) is the only
infrastructure: phones and Dart hosts reach it over UDX
(`/ip4/152.42.240.103/udp/55223/udx`), browsers over WSS
(`/dns4/ricochet.spiffyvault.net/tcp/55223/wss`, or plain `/ws` from http
pages). Test hosts dial relays over TCP or UDX.

Coordination moved onto libp2p so phones work from any network: the phone
reserves on the relay and opens `/webrtc-interop/dial-back/1.0.0` to the
hub's Dart host through it (`lib/src/interop/libp2p_dialback.dart`); the
hub's Dart host and headless Chrome dial the phone over `/webrtc` and stream
results back on that stream; then the phone dials both and reports on
`/webrtc-interop/report/1.0.0`. `tool/libp2p_hub.dart --relay <udx>
--relay-browser <wss>` (persistent hub identity in build/) and
`tool/ricochet_session_check.dart` (the whole session from one machine).

Results, 25/25 per session, every direction direct (the relay carries only
signaling):
- Pixel on home Wi-Fi: Dart and Chrome ↔ phone, IPv6 and IPv4 host paths.
- iPhone on cellular, Mac and Chrome at home (two sessions): Chrome dials
  the phone through ricochet in 1.1–1.2 s, phone dials Chrome back in
  0.7–0.8 s; pings 28–133 ms; 1 MiB round trips 1.5–8 s (cellular).
- Same setup, with the browser page using the published
  `@stephanfeb/libp2p-udx/multiaddr` 0.1.1 from npm for the UDX codec
  (instead of registering it inline): Chrome dials the phone in 1.7 s,
  phone dials Chrome back in 0.9 s; pings 51–137 ms; 1 MiB round trips
  3–11 s, all srflx ↔ srflx or host ↔ srflx over IPv6.

Every off-LAN path ran over IPv6 (the carrier's IPv6 has no NAT; the home
router's IPv6 was enabled during testing). With IPv4 only on one side and
the carrier's symmetric NAT on the other, direct WebRTC fails (see "Phones,
cellular" above), so production still needs TURN (proven with coturn; a
hosted service, configured in the app and the web page).

Interop finding: js-libp2p rejects a whole relay reservation whose
addresses include `/udx` ("Protocol 768 was unknown"). Web apps using
go-ricochet must register the codec first:
`registry.addProtocol({ code: 0x0300, name: 'udx', size: 0 })` from
`@multiformats/multiaddr`, as js-udx's `packages/libp2p-udx/src/multiaddr.ts`
does. (Alternatively the relay could leave `/udx` out of reservations made
over WebSockets.)

## 1. Package layout

A separate package so `dart_libp2p` stays pure Dart with no native build.

```
dart_libp2p_webrtc/
  hook/build.dart                  # Dart build hook: CMake-builds libdatachannel
  third_party/libdatachannel/      # git submodule, pinned tag
  ffigen.yaml                      # generates bindings from include/rtc/rtc.h
  lib/
    dart_libp2p_webrtc.dart        # exports WebRtcTransport
    src/ffi/
      bindings.g.dart              # ffigen output (C API only, no C++)
      rtc_runtime.dart             # init, logger, shared NativeCallables, id→handler map
      rtc_peer_connection.dart     # Dart wrapper: Futures/Streams over a pc id
      rtc_data_channel.dart        # Dart wrapper: polled receive, backpressure
    src/signaling/
      signaling.proto              # /webrtc-signaling/0.0.1 Message
      signaling_session.dart       # offerer / answerer state machines
    src/stream/
      message.proto                # stream framing: flag + message
      webrtc_stream.dart           # P2PStream + MuxedStream over one data channel
    src/webrtc_conn.dart           # Conn + MuxedConn + UpgradedTransportConn
    src/webrtc_transport.dart      # Transport (dial / listen / canDial)
    src/webrtc_listener.dart       # Listener fed by the signaling handler
```

### Native build

- libdatachannel built with `NO_MEDIA=ON`, `NO_WEBSOCKET=ON`, `NO_EXAMPLES=ON`,
  `NO_TESTS=ON` (data channels only). It bundles libjuice (ICE) and usrsctp.
- TLS backend: **Mbed TLS 3.6 LTS** (`USE_MBEDTLS=ON`), vendored as a submodule
  and linked statically, to keep the binary small and avoid shipping OpenSSL.
  libdatachannel needs `MBEDTLS_SSL_DTLS_SRTP` even without media
  (`native/mbedtls_user_config.h`). OpenSSL is the fallback if Mbed TLS DTLS
  interop with browsers has issues.
- Targets: iOS (static, xcframework), Android (`.so` per ABI via NDK), and
  macOS/Linux for tests and the `interop/` harness.
- Built from `hook/build.dart` (Dart native assets), so `dart test` and
  `flutter build` both pick it up without a separate plugin.

## 2. FFI layer

### 2.1 The callback/threading problem

libdatachannel invokes callbacks on its own threads. Dart's only safe option
for that is `NativeCallable.listener`, which runs the Dart callback
**asynchronously, after the native callback has returned**. Any `const char*`
argument (SDP, candidate, message bytes, error text) is therefore dangling by
the time Dart runs.

**v1 design: only accept integer arguments in callbacks, pull data
synchronously.**

| Need | Callback used (int args only) | How data is fetched |
|---|---|---|
| Local SDP | `rtcSetGatheringStateChangeCallback` → COMPLETE | `rtcGetLocalDescription(pc, buf, size)` (candidates embedded, no trickle) |
| Remote SDP / candidates | — (Dart → native) | `rtcSetRemoteDescription`, `rtcAddRemoteCandidate` (strings are copied by the C API) |
| Connection state | `rtcSetStateChangeCallback(pc, state)` | — |
| Inbound data channel | `rtcSetDataChannelCallback(pc, dc)` | — |
| Channel open / closed | `rtcSetOpenCallback`, `rtcSetClosedCallback` | — |
| Messages | `rtcSetAvailableCallback(id)` (**no** message callback set → polling mode) | loop `rtcReceiveMessage(id, buf, &size)` until `RTC_ERR_NOT_AVAIL` |
| Backpressure | `rtcSetBufferedAmountLowCallback(id)` | `rtcGetBufferedAmount(id)` |
| Errors | `rtcSetErrorCallback(id, msg)` | message text ignored; treated as fatal for that id |

Cost: no trickle ICE on our side, so we wait for gathering to finish before
sending the offer/answer (~0.5–2 s depending on STUN reachability). We still
*accept* trickled candidates from the browser.

**v2 option:** a ~150-line C shim that registers the string callbacks, copies
the data, and posts it to a Dart `ReceivePort` via `Dart_PostCObject_DL`.
Enables trickle and removes the polling round-trip. Only worth it if gathering
latency matters in practice.

### 2.2 rtc_runtime.dart

- One `NativeCallable.listener` **per callback type**, created once per isolate
  and shared by every pc/dc. Each dispatches on the `int id` through
  `Map<int, _PcHandler>` / `Map<int, _DcHandler>`. This keeps the number of
  callables fixed and avoids leaking one per connection.
- `rtcInitLogger` once, forwarding to `package:logging` (the logger callback
  has a string, so v1 uses `RTC_LOG_NONE` in release and stderr in debug).
- A reusable 16 KiB + slack receive buffer (`malloc`) per isolate. Spec caps
  messages at 16 KiB, so one buffer serves every channel.
- `dispose()` → `rtcCleanup()`, close the callables.

### 2.3 RtcPeerConnection (Dart wrapper)

```dart
class RtcPeerConnection {
  static RtcPeerConnection create(RtcConfig cfg); // rtcCreatePeerConnection
  Future<String> createOffer();                    // setLocalDescription("offer") + await gathering complete
  Future<String> createAnswer();                   // setLocalDescription("answer") + await gathering complete
  void setRemoteDescription(String sdp, String type);
  void addRemoteCandidate(String candidate, String? mid);
  Stream<RtcState> get states;                     // connecting/connected/disconnected/failed/closed
  Stream<RtcDataChannel> get incomingChannels;
  RtcDataChannel createDataChannel({String label = ''}); // rtcCreateDataChannelEx
  (String, int)? get remoteAddress;                // rtcGetRemoteAddress → for remoteMultiaddr
  Future<void> close();                            // rtcClosePeerConnection + rtcDeletePeerConnection, unregister
}
```

`RtcConfig`: ICE servers (STUN by default; TURN optional, see §6), port range,
`maxMessageSize = 16384`.

### 2.4 RtcDataChannel (Dart wrapper)

```dart
class RtcDataChannel {
  Stream<Uint8List> get messages;  // filled by the available-callback drain loop
  Future<void> get opened;
  Future<void> get closed;
  Future<void> send(Uint8List msg); // awaits bufferedAmountLow when above high-water mark
  int get streamId;                 // rtcGetDataChannelStream
  Future<void> close();             // rtcClose + rtcDelete, unregister
}
```

Backpressure: high-water 1 MiB, low-water threshold 256 KiB
(`rtcSetBufferedAmountLowThreshold`). `send` checks `rtcGetBufferedAmount`
before each message and parks on the low-water callback when over.

## 3. libp2p layer

### 3.1 Addressing

```
/ip4/<relay>/tcp/443/wss/p2p/<RELAY>/p2p-circuit/webrtc/p2p/<TARGET>
\_____________ relayed address of TARGET ___________/\_____/
                                                     marks "upgrade to WebRTC"
```

`canDial`: has a `webrtc` component (not `webrtc-direct`) that follows
`p2p-circuit`. Strip `/webrtc` to get the relayed address used for signaling.

### 3.2 Signaling (`/webrtc-signaling/0.0.1`)

Varint-length-prefixed protobuf:

```proto
message Message {
  enum Type { SDP_OFFER = 0; SDP_ANSWER = 1; ICE_CANDIDATE = 2; }
  optional Type type = 1;
  optional string data = 2;   // SDP text, or JSON RTCIceCandidateInit
}
```

**Dialer (offerer)** — `WebRtcTransport.dial(addr)`:
1. Connect to TARGET over the relayed address (circuit v2; a *limited* conn).
2. Open `/webrtc-signaling/0.0.1` on it — must be allowed on limited conns.
3. Create pc; create one data channel so the offer contains `m=application`.
4. `createOffer()` → send `SDP_OFFER`.
5. Read `SDP_ANSWER` → `setRemoteDescription`; apply every `ICE_CANDIDATE`
   received until the pc reaches `connected` (or timeout, default 30 s).
6. Close the signaling stream. Wrap the pc in `WebRtcConn`.

**Listener (answerer)** — stream handler registered by `listen()`:
1. Read `SDP_OFFER` → create pc → `setRemoteDescription`.
2. `createAnswer()` → send `SDP_ANSWER`. Apply incoming candidates.
3. On `connected`, push a `WebRtcConn` into the listener's `connectionStream`.

Both roles are supported: the phone can be dialed by a browser, and can dial a
browser that holds a relay reservation.

### 3.3 Security

For `/webrtc` there is **no Noise handshake** (js-libp2p upgrades with
`skipEncryption: true`): the SDP — including both DTLS certificate fingerprints
— travels over the relayed libp2p connection, which is already
Noise-authenticated end-to-end. libdatachannel verifies the peer's DTLS
certificate against the SDP fingerprint, so the WebRTC session is bound to the
peer ID of the relayed connection.

Consequences:
- `remotePeer` = the relayed conn's remote peer; `remotePublicKey` from that
  conn / peerstore.
- `ConnState(security: '', streamMultiplexer: '', transport: 'webrtc')`.

> ⚠ Verify against the current libp2p `webrtc.md` spec and js-libp2p before
> implementing; if a Noise step has been added, the existing
> `NoiseSecurity` needs prologue support (it currently hard-codes an empty
> prologue in `xx_pattern.dart`).

### 3.4 Streams

One libp2p stream = one data channel (label `""`, ordered, reliable). Each
message is varint-length-prefixed protobuf, total ≤ 16 KiB:

```proto
message Message {
  enum Flag { FIN = 0; STOP_SENDING = 1; RESET_STREAM = 2; FIN_ACK = 3; }
  optional Flag flag = 1;
  optional bytes message = 2;
}
```

`WebRtcStream implements P2PStream<Uint8List>, MuxedStream`:
- `write` chunks into ≤ 16 KiB frames (minus header overhead).
- `closeWrite` → send `FIN`, wait for `FIN_ACK` (bounded timeout), then the
  channel can be closed once both directions are done.
- `closeRead` → send `STOP_SENDING`.
- `reset` → send `RESET_STREAM`, close the channel immediately.
- Receiving `FIN` → EOF to readers, reply `FIN_ACK`.
- Protocol negotiation (multistream-select) runs per stream as on any other
  conn; nothing WebRTC-specific.

### 3.5 WebRtcConn

```dart
class WebRtcConn implements TransportConn, MuxedConn, UpgradedTransportConn {
  // openStream  → pc.createDataChannel() → WebRtcStream
  // acceptStream → next from pc.incomingChannels → WebRtcStream
  // close        → reset open streams, pc.close()
  // pc state failed/closed → mark closed, notify swarm
}
```

It implements `MuxedConn` because `Swarm._handleIncomingStreams`
(`swarm.dart:649`) casts the conn to `MuxedConn` and loops on `acceptStream()`.

## 4. Changes made in dart-libp2p core (main, bf1539a)

1. **`UpgradedTransportConn`** (`core/network/transport_conn.dart`,
   `implements TransportConn, MuxedConn`): the swarm uses such a connection
   as it is on dial and accept, skipping the upgrader.
2. **`PushbackStream`** (`core/network/mux.dart`): multistream-select puts
   bytes read past its negotiation back into any stream implementing it
   (YamuxStream and WebRtcStream do), not only Yamux.
3. **`Swarm.isRelayedRoute`**: a `/p2p-circuit/webrtc` address is not a
   relayed route, so `forceDirectDial` keeps it and circuit dedup does not
   drop it in favour of the plain circuit address through the same relay.
4. **Address advertisement** (`BasicHost.allAddrs`): a bare `/webrtc`
   listen address is not advertised; when one exists, each AutoRelay
   address is also advertised with `/webrtc` appended.

Not needed: `CircuitV2Client.canDial` already rejects `/p2p-circuit/webrtc/…`
(it requires `/p2p` right after `/p2p-circuit`), and TCP/UDX reject any
circuit address. Signaling on limited connections works: tested through a
go-libp2p relay with its default limits (see "go-libp2p interop").

## 5. Test and interop plan

1. FFI smoke test: two `RtcPeerConnection`s in one Dart process, loopback,
   SDP passed in memory, echo over a data channel.
2. Two dart-libp2p hosts + an in-process circuit relay: dial via `/webrtc`,
   run ping and identify, check that the conn is direct (non-limited) after.
3. js-libp2p in headless Chrome, Firefox and WebKit (Playwright) ↔ Dart peer
   via a go-libp2p relay with WSS. Cover both directions (browser dials phone,
   phone dials browser).
4. On-device runs: iOS and Android over Wi-Fi and over cellular (carrier-grade NAT).

## 6. Risks and open questions

- **Carrier-grade NAT / symmetric NAT:** ICE fails for some phone↔browser
  pairs. Options: keep traffic on the relay (needs a relay with relaxed
  limits) or configure TURN in `RtcConfig.iceServers` — libdatachannel
  supports TURN; the browser side would need the same TURN servers.
- **Mobile background suspension:** iOS/Android suspend UDP sockets, so ICE
  consent fails and the pc goes `failed`. Treat it as a normal disconnect and
  re-dial on resume.
- **Binary size (measured, v0.24.6 + Mbed TLS 3.6.7):** 2.7 MB macOS/iOS
  arm64, 3.9 MB Linux arm64, 3.7 MB Android arm64 after stripping (33 MB
  unstripped; Flutter strips when packaging).
- **API names:** the C API names in §2 are from `rtc/rtc.h` as of recent
  releases; regenerate with ffigen against the pinned tag and adjust.
- **Swapability:** keep all libdatachannel use behind `RtcPeerConnection` /
  `RtcDataChannel`. A future pure-Dart ICE/DTLS/SCTP stack can implement the
  same two classes without touching §3.

## 7. Rough effort

| Piece | Estimate |
|---|---|
| Native build hook (iOS, Android, desktop) | 1–2 weeks |
| FFI wrapper (§2) | 1 week |
| Signaling + transport + listener (§3.1–3.2) | 1–2 weeks |
| Stream framing + conn (§3.4–3.5) | 1 week |
| Core changes (§4) | 2–4 days |
| Browser interop + device testing | 2 weeks |
| **Total** | **~6–9 weeks, one engineer** |

## Releasing

0.1.0 is published on pub.dev (tag `v0.1.0`), with dart_libp2p 4.9.0 from
pub.dev (no `pubspec_overrides.yaml`). The guides in `doc/` are published on
cryptopeer.net/libp2p/webrtc/ (synced by the cryptopeer.net repo, which
redeploys on a push there). For each release:

1. `dart test` (with `NODE` for the browser tests) and `flutter analyze` in
   `example/interop_app`.
2. `tool/check_package.sh`: builds the native library from exactly the
   published file set (`.pubignore` uses anchored paths only, which the
   script maps to rsync excludes).
3. `dart pub publish --dry-run`. Expected: a notice about three
   gitignored files under `third_party/libdatachannel/deps/json` (excluded
   anyway; it comes from that submodule's `.gitignore`).
4. Push the repository and tags to github.com/stephanfeb/dart-libp2p-webrtc,
   then `dart pub publish`.

The published package is the transport (`lib/` minus the interop harness),
the build hook and the trimmed native sources (about 3 MB compressed); the
interop harness, tools, Docker setup and this file stay in the repository.
