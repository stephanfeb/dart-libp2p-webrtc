# Browsers

A web app running js-libp2p and a Dart or Flutter app reach each other the
same way two Dart hosts do: both book a slot on a circuit relay, one dials
the other's `/p2p-circuit/webrtc` address, and WebRTC takes over from there.
This guide sets up the browser side, and covers what the relay needs.

The JavaScript here comes from the page the [interop tests](interop.md) run
in Chrome, Firefox and WebKit against dart_libp2p hosts.

## The relay

The browser and the Dart app must reach the same relay, each over a
transport it has:

| Peer | Reaches the relay over |
|---|---|
| Browser | WebSockets: `/wss` from a page served over HTTPS, `/ws` only from `http://` pages (browsers block `ws://` from secure pages) |
| Dart or Flutter app | TCP or UDX (dart_libp2p has no WebSocket transport) |

So the relay listens on a WebSocket address, ideally with TLS, and on TCP
or UDX. A go-libp2p relay can share one TCP port between raw TCP and
WebSockets. For example, a [go-ricochet](../../go-ricochet/README.md) server
configured like this serves browsers and Dart apps:

```yaml
transports: [udx, tcp, websocket]
listen_addresses:
  - /ip4/0.0.0.0/udp/55223/udx
  - /ip4/0.0.0.0/tcp/55223
  - /ip4/0.0.0.0/tcp/55223/ws
  - /ip4/0.0.0.0/tcp/55223/tls/ws
```

The relay only carries signaling, a few KB per connection, so go-libp2p's
default relay limits (2 minutes, 128 KiB per relayed connection) are plenty.

## The browser node

Install js-libp2p with the WebSockets, WebRTC and circuit relay
transports:

```sh
npm install libp2p @libp2p/websockets @libp2p/webrtc @libp2p/circuit-relay-v2 \
  @chainsafe/libp2p-noise @chainsafe/libp2p-yamux @libp2p/identify @libp2p/ping \
  @multiformats/multiaddr
```

If the relay also speaks UDX, as go-ricochet and dart_libp2p relays can,
register the UDX multiaddr codec first. The relay lists its `/udx` address in
the reservation it grants, and without the codec js-libp2p rejects the whole
reservation with `Protocol 768 was unknown`:

<!-- example: interop/browser/libp2p-page.js#udx-codec -->
```js
// UDX relays (go-ricochet) list their /udx address in reservations; without
// the codec js-libp2p fails the whole reservation ("Protocol 768 was
// unknown"). Same registration as js-udx's packages/libp2p-udx/src/multiaddr.ts.
registry.addProtocol({ code: 0x0300, name: 'udx', size: 0 })
```
<!-- /example -->

Then create the node. It listens on `<relay>/p2p-circuit`, which books a
reservation on that relay, and on `/webrtc`, which accepts WebRTC
connections signaled through it:

<!-- example: interop/browser/libp2p-page.js#node -->
```js
const node = await createLibp2p({
  addresses: { listen: [`${relay}/p2p-circuit`, '/webrtc'] },
  transports: [webSockets(), webRTC({ rtcConfiguration }), circuitRelayTransport()],
  connectionEncrypters: [noise()],
  streamMuxers: [yamux()],
  // The test relay and Dart host are on loopback, which browsers' default
  // gater refuses.
  connectionGater: { denyDialMultiaddr: async () => false },
  services: { identify: identify(), ping: ping() }
})
console.log(`browser peer ${node.peerId}`)
await node.handle(ECHO, async (stream) => {
  for await (const chunk of stream) {
    if (!stream.send(chunk)) await stream.onDrain()
  }
  await stream.close()
})
```
<!-- /example -->

- `relay` is the relay's WebSocket address with its peer ID, for example
  `/dns4/relay.example.com/tcp/443/wss/p2p/12D3KooW…`.
- `rtcConfiguration` holds the browser's ICE servers. It's `undefined` here
  (js-libp2p's defaults include public STUN servers); for TURN, see
  [Networks](networks.md).
- The `connectionGater` override is only for the tests, which run on
  loopback. A web app talking to public addresses doesn't need it.
- `ECHO` is a protocol ID (`/test/echo/1.0.0`); the handler sends back
  every chunk it reads. Your own protocols go here the same way.

## Browser dials the Dart app

Once the Dart app has a reservation on the relay (see
[Getting started](getting-started.md)), the browser dials its WebRTC
address, `<relay>/p2p-circuit/webrtc/p2p/<dart peer id>`:

<!-- example: interop/browser/libp2p-page.js#dial -->
```js
const connection = await node.dial(target, { signal: AbortSignal.timeout(30_000) })
```
<!-- /example -->

js-libp2p opens the relayed connection, runs the signaling protocol over
it, and returns the WebRTC connection. It reports `/webrtc` as the
multiplexer and `native` as the encryption, and it isn't limited, even
though the relayed connection it came through is.

Streams work as on any js-libp2p connection. This helper sends a buffer on a
new stream, half-closes it, and collects the reply:

<!-- example: interop/browser/libp2p-page.js#echo-client -->
```js
/** Sends `data` on a fresh echo stream, half-closes, and returns the reply. */
async function echo (connection, data) {
  const stream = await connection.newStream(ECHO)
  const reply = (async () => {
    const chunks = []
    for await (const chunk of stream) chunks.push(chunk.subarray())
    const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0))
    let offset = 0
    for (const c of chunks) { out.set(c, offset); offset += c.length }
    return out
  })()
  for (let offset = 0; offset < data.length; offset += 16 * 1024) {
    if (!stream.send(data.subarray(offset, offset + 16 * 1024))) await stream.onDrain()
  }
  await stream.close()
  return reply
}
```
<!-- /example -->

On the Dart side, the incoming connection joins the host's swarm. The host's
stream handlers serve the browser's streams, and identify and ping answer as
they would over TCP.

## The Dart app dials the browser

The other direction works the same as between two Dart hosts. The browser
has a reservation on the relay, from listening on `<relay>/p2p-circuit`.
The Dart app connects to it through the relay, then upgrades, exactly as the
dialer in [Getting started](getting-started.md#two-hosts-a-relay-and-webrtc)
does:

1. `connect` to the relay (over TCP or UDX).
2. `connect` to the browser at `<relay>/p2p-circuit`.
3. `WebRtcTransport.upgrade(browserPeerId)`.

The browser's `/webrtc` listener answers the offer, and the Dart app gets a
direct connection to the browser.

## Checklist

- The relay listens on WSS for HTTPS pages, and on TCP or UDX for Dart.
- The page registers the UDX codec if the relay speaks UDX.
- Both sides have STUN servers: js-libp2p does by default, Dart needs them in
  `RtcConfig.iceServers`.
- For networks without a direct path, both sides have the same TURN server
  (see [Networks](networks.md)).
