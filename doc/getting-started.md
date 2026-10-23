# Getting started

## Install

```sh
dart pub add dart_libp2p_webrtc
# or, in a Flutter app:
flutter pub add dart_libp2p_webrtc
```

The package needs Dart 3.10 or later (Flutter 3.38 or later) and
dart_libp2p 4.9.0 or later.

### Build tools

The first build compiles libdatachannel and Mbed TLS from source, through
the package's build hook. It needs:

| Tool | For |
|---|---|
| [CMake](https://cmake.org/) 3.21 or later | every platform |
| [Ninja](https://ninja-build.org/) | every platform |
| Xcode | macOS and iOS |
| Android NDK (the one Flutter uses) | Android |
| GCC or Clang | Linux |

Both CMake and Ninja must be on `PATH`. On macOS: `brew install cmake ninja`.
On Debian or Ubuntu: `apt install cmake ninja-build g++`.

The first build takes a few minutes; after that it's cached. The library adds
about 3 to 4 MB per platform and ABI. Windows and the web aren't supported:
in a browser, use js-libp2p's own WebRTC transport.

## Two hosts, a relay, and WebRTC

This program starts two hosts. One books a slot on a circuit relay; the other
reaches it through the relay, then moves onto a direct WebRTC connection and
opens a stream over it.

Each host gets the WebRTC transport, listens on `/webrtc`, and has the
circuit relay client turned on. TCP is there to reach the relay; use UDX if
your relay speaks it.

<!-- example: example/example.dart#host -->
```dart
/// A host with the WebRTC transport, listening on `/webrtc`, and TCP to
/// reach the relay. The WebRTC transport goes first: the swarm uses the
/// first transport that can dial an address.
Future<(Host, WebRtcTransport)> _host() async {
  final connManager = ConnectionManager();
  final webrtc = WebRtcTransport(
    rtcConfig: const RtcConfig(iceServers: ['stun:stun.l.google.com:19302']),
  );
  final host = await Libp2p.new_([
    Libp2p.connManager(connManager),
    Libp2p.transport(webrtc),
    Libp2p.transport(TCPTransport(connManager: connManager)),
    Libp2p.listenAddrs([MultiAddr('/webrtc')]),
    Libp2p.relay(true),
  ]);
  webrtc.attach(host); // before start: the signaling handler needs the host
  await host.start();
  return (host, webrtc);
}
```
<!-- /example -->

Three things matter here:

- **Order.** Add the WebRTC transport before the others. The swarm dials an
  address with the first transport that accepts it.
- **`attach` before `start`.** The transport answers signaling streams on the
  host, so it needs the host before the host starts listening.
- **`/webrtc` as a listen address.** That is how the host accepts WebRTC
  connections. With AutoRelay, the host then advertises
  `<relay>/p2p-circuit/webrtc` addresses.

The listener connects to the relay and books a reservation, so peers can
reach it through the relay:

<!-- example: example/example.dart#listener -->
```dart
// The listener books a slot on the relay so peers can reach it there.
final (listener, _) = await _host();
listener.setStreamHandler(_hello, (stream, peer) async {
  await stream.write(utf8.encode('hello from ${listener.id} over ${stream.conn.remoteMultiaddr}'));
  await stream.close();
});
await listener.connect(relay);
await (listener as BasicHost).circuitV2Client!.reserve(relay.id);
```
<!-- /example -->

The dialer connects to the listener through the relay, then calls
`upgrade`. WebRTC's offer and answer go over the relayed connection, and the
result is a direct connection that new streams prefer:

<!-- example: example/example.dart#dialer -->
```dart
// The dialer reaches it through the relay (which it must be connected to,
// or at least know the address of), then upgrades to WebRTC.
final (dialer, webrtc) = await _host();
await dialer.connect(relay);
await dialer.connect(AddrInfo(listener.id, [MultiAddr('${args.first}/p2p-circuit')]));
final conn = await webrtc.upgrade(listener.id);
print('direct connection: ${conn.remoteMultiaddr}');

// New streams prefer the direct connection.
final stream = await dialer.newStream(listener.id, [_hello], Context());
print(utf8.decode(await stream.read()));
```
<!-- /example -->

The dialer has to know the relay before it dials *through* it: dart_libp2p's
circuit client looks the relay up in the peerstore, so connect to it first
(or add its address to the peerstore).

## Run it

You need a circuit relay. Any libp2p relay works: a dart_libp2p host with
`Libp2p.relay(true)` and public reachability, a go-libp2p host with
`EnableRelayService`, or a js-libp2p node with `circuitRelayServer`. See
[Circuit Relay v2](../../dart-libp2p/doc/relay-setup-guide.md) for running
one with dart_libp2p.

```sh
dart run example/example.dart /ip4/<relay-ip>/tcp/<port>/p2p/<relay-id>
```

```
direct connection: /ip6/2001:db8::7/udp/53756/webrtc
hello from 12D3KooW… over /ip6/2001:db8::7/udp/53756/webrtc
```

The remote address is the peer's selected ICE candidate, followed by
`/webrtc`. It never contains `/p2p-circuit`: the connection is direct, and
dart_libp2p treats any `/p2p-circuit` address as relayed.

## Next

- [Browsers](browsers.md): the same, with a js-libp2p web app on one side.
- [Networks](networks.md): what to configure so peers on different networks connect.
