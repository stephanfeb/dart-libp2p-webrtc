// Browser side of test/interop/js_libp2p_interop_test.dart: a js-libp2p node
// that dials the Dart host's /p2p-circuit/webrtc address (via the relay over
// WebSockets) and exercises the WebRTC connection, then listens on /webrtc
// through the relay for the Dart host to dial it back. Bundled with esbuild.
//
// Results go to the console as `RESULT <json>` lines, which the Playwright
// driver forwards to the Dart test.
import { selectedPath } from './capture-pc.js'
import { noise } from '@chainsafe/libp2p-noise'
import { yamux } from '@chainsafe/libp2p-yamux'
import { circuitRelayTransport } from '@libp2p/circuit-relay-v2'
import { identify } from '@libp2p/identify'
import { ping } from '@libp2p/ping'
import { webRTC } from '@libp2p/webrtc'
import { webSockets } from '@libp2p/websockets'
import { multiaddr } from '@multiformats/multiaddr'
// #region udx-codec
// UDX relays (go-ricochet) list their /udx address in reservations; without
// the UDX codec js-libp2p fails the whole reservation ("Protocol 768 was
// unknown"). This browser entry registers it.
import '@stephanfeb/libp2p-udx/multiaddr'
// #endregion udx-codec
import { createLibp2p } from 'libp2p'

const ECHO = '/test/echo/1.0.0'
const params = new URLSearchParams(location.search)
const target = multiaddr(params.get('target'))
const relay = params.get('relay')
// With turn=turn:host:port (and turnUser, turnPass), WebRTC may only use
// relay candidates from that TURN server.
const turn = params.get('turn')
const rtcConfiguration = turn == null
  ? undefined
  : {
      iceServers: [{ urls: turn, username: params.get('turnUser'), credential: params.get('turnPass') }],
      iceTransportPolicy: 'relay'
    }

// Echoed in every result, so one driver can run several pages.
const runId = params.get('run')

function result (name, ok, detail) {
  console.log(`RESULT ${JSON.stringify({ run: runId, name, ok, detail })}`)
}

function pattern (length, seed) {
  const out = new Uint8Array(length)
  for (let i = 0; i < length; i++) out[i] = (i * 31 + seed) & 255
  return out
}

function equal (a, b) {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

// #region echo-client
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
// #endregion echo-client

async function run () {
  // #region node
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
  // #endregion node

  const started = performance.now()
  // #region dial
  const connection = await node.dial(target, { signal: AbortSignal.timeout(30_000) })
  // #endregion dial
  result('dial', true, `${connection.remoteAddr} in ${Math.round(performance.now() - started)} ms; ` +
    `muxer ${connection.multiplexer ?? '-'}, encryption ${connection.encryption ?? '-'}, ` +
    `limited ${connection.limits != null}, direction ${connection.direction}`)

  const path = await selectedPath()
  result('path', path != null, JSON.stringify(path))

  const rtt = await node.services.ping.ping(target)
  result('ping', true, `${rtt} ms`)

  const small = pattern(1000, 7)
  result('echo-small', equal(await echo(connection, small), small), '1000 bytes')

  const big = pattern(1024 * 1024, 11)
  const bigStarted = performance.now()
  const bigReply = await echo(connection, big)
  result('echo-1mib', equal(bigReply, big),
    `${bigReply.length} bytes in ${Math.round(performance.now() - bigStarted)} ms`)

  const replies = await Promise.all(Array.from({ length: 16 }, (_, i) => echo(connection, pattern(2048, i))))
  result('echo-16-streams', replies.every((r, i) => equal(r, pattern(2048, i))), '16 x 2048 bytes')

  const identified = await node.peerStore.get(connection.remotePeer)
  result('identify', identified.protocols.includes(ECHO),
    `remote protocols: ${identified.protocols.join(' ')}`)

  await connection.close()
  result('done', true, '')

  // Now the Dart host dials us: wait for the relay reservation.
  while (!node.getMultiaddrs().some(a => a.toString().includes('/p2p-circuit/webrtc'))) {
    await new Promise(resolve => setTimeout(resolve, 100))
  }
  result('listening', true, `${node.peerId}`)
}

run().catch(err => {
  console.log(`error: ${err.stack ?? err}`)
  result('fatal', false, String(err))
})
