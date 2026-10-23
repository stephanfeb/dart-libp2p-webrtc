# Flutter and mobile

The package works the same in a Flutter app as in a Dart program: add it,
build, and the build hook compiles the native library for each target.
This page covers what's specific to phones.

```sh
flutter pub add dart_libp2p_webrtc
```

## Building

| Platform | Needs | Ships |
|---|---|---|
| Android | CMake, Ninja, and the NDK Flutter uses | `libdatachannel.so` per ABI, about 3.7 MB stripped |
| iOS | CMake, Ninja, Xcode | `datachannel.framework`, about 2.7 MB |
| macOS | CMake, Ninja, Xcode | `libdatachannel.dylib` |
| Linux | CMake, Ninja, GCC or Clang | `libdatachannel.so` |

The library links its dependencies (libjuice, usrsctp, Mbed TLS) statically,
so it's one self-contained file per platform; Flutter bundles it like any
native asset. The first build of each target takes a few minutes.

## Permissions

**Android** needs network access in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

**iOS** asks the user before an app talks to devices on the local network,
and ICE tries local-network candidates. Add the reason iOS shows in that
prompt to `ios/Runner/Info.plist`; if the user declines, connections to
peers on the same network can't use local addresses:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connects directly to peers on your network.</string>
```

Connections over the internet don't need this, but a peer on the same Wi-Fi
is a local-network peer.

## What changes on a phone

**Signaling needs a relay the phone can reach.** Phones reach relays over TCP
or UDX (dart_libp2p has no WebSocket transport). A relay on a public address
works from any network; a relay on your laptop only works on the same
Wi-Fi.

**Cellular networks are the hard case.** Carriers usually put IPv4 behind a
*symmetric* NAT, which defeats direct connections over IPv4. Many carriers
give phones IPv6 without NAT, so a direct connection works when the other
side has IPv6 too. Where neither works, TURN carries the traffic. See
[Networks](networks.md) for what to expect and what to configure.

**Add STUN servers.** Without them a phone only knows its local addresses,
which nobody outside its network can reach:

```dart
WebRtcTransport(
  rtcConfig: const RtcConfig(iceServers: ['stun:stun.l.google.com:19302']),
)
```

**Background and network changes.** This package hasn't been tested yet
with an app going to the background or a phone switching between Wi-Fi and
cellular. Expect the WebRTC connection to drop: when its peer connection
fails or closes, the connection leaves the swarm. Upgrade again when the app
comes back; the relayed connection is the fallback.

## Testing on devices

Some things worth knowing when you test on real phones:

- **iOS debug builds stop when the debugger detaches.** To test away from
  the cable (on cellular, say), install a release build:
  `flutter run --release`.
- **A phone on a USB cable has an extra network.** With an iPhone plugged
  into a Mac, ICE can pick the USB link, which looks like a fast direct
  connection. Unplug before measuring.
- **Turn Wi-Fi off to test cellular.** iOS keeps cellular up next to Wi-Fi,
  and ICE gathers candidates on both.

The repository's `example/interop_app` is a Flutter app that runs a full
session against a desktop hub (a relay, a Dart host and a headless browser),
in all four directions; [Interoperability](interop.md) has the results from
an Android and an iOS phone.
