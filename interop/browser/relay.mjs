// Circuit relay v2 server for test/interop/js_libp2p_interop_test.dart: TCP
// for the Dart host, WebSockets for the browser. Prints one JSON line with its
// peer id and addresses, then runs until stdin closes.
import { noise } from '@chainsafe/libp2p-noise'
import { yamux } from '@chainsafe/libp2p-yamux'
import { circuitRelayServer } from '@libp2p/circuit-relay-v2'
import { identify } from '@libp2p/identify'
import { ping } from '@libp2p/ping'
import { tcp } from '@libp2p/tcp'
import { webSockets } from '@libp2p/websockets'
import { createLibp2p } from 'libp2p'

const node = await createLibp2p({
  addresses: { listen: ['/ip4/127.0.0.1/tcp/0', '/ip4/127.0.0.1/tcp/0/ws'] },
  transports: [tcp(), webSockets()],
  connectionEncrypters: [noise()],
  streamMuxers: [yamux()],
  services: {
    identify: identify(),
    ping: ping(),
    // Relayed connections only carry signaling here, but keep the default
    // data/duration limits off so a slow test can't trip them.
    relay: circuitRelayServer({ reservations: { applyDefaultLimit: false, maxReservations: 64 } })
  }
})

console.log(JSON.stringify({
  peerId: node.peerId.toString(),
  addrs: node.getMultiaddrs().map(String)
}))

process.stdin.on('end', () => node.stop().then(() => process.exit(0)))
process.stdin.resume()
