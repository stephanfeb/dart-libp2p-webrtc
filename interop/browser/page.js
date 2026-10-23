// Browser side of the interop scenarios. Served by InteropServer
// (lib/src/interop), which relays signaling to the Dart peer running the same
// scenario (lib/src/interop/scenarios.dart). Signaling is JSON over a WebSocket:
//   {type: 'offer'|'answer', sdp}  {type: 'candidate', candidate, mid}
//   {type: 'result', ok, detail}   (page → Dart, ends the scenario)
const params = new URLSearchParams(location.search);
const scenario = params.get('scenario');
const ws = new WebSocket(`ws://${location.host}/signal?role=browser&scenario=${scenario}&run=${params.get('run')}`);
const inbox = [];
let waiter = null;

ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (waiter) {
    const w = waiter;
    waiter = null;
    w(msg);
  } else {
    inbox.push(msg);
  }
};

const send = (msg) => ws.send(JSON.stringify(msg));
const next = () => (inbox.length ? Promise.resolve(inbox.shift()) : new Promise((r) => (waiter = r)));
const report = (ok, detail = '') => send({ type: 'result', ok, detail });

/** Deterministic payload: byte i of a stream at absolute offset o is (o*31+7)&255. */
function pattern(offset, length) {
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) out[i] = ((offset + i) * 31 + 7) & 255;
  return out;
}

function equal(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function newPeer() {
  // Same STUN/TURN servers as the Dart peer (comma-separated `ice` param).
  const ice = params.get('ice');
  const pc = new RTCPeerConnection({ iceServers: ice ? ice.split(',').map((urls) => ({ urls })) : [] });
  pc.onicecandidate = (e) =>
    send({ type: 'candidate', candidate: e.candidate ? e.candidate.candidate : null, mid: e.candidate?.sdpMid ?? null });
  pc.onconnectionstatechange = () => console.log(`connectionState=${pc.connectionState}`);
  return pc;
}

/** Browser offers (trickling candidates); Dart answers with candidates in SDP. */
async function offerToDart(pc) {
  await pc.setLocalDescription(await pc.createOffer());
  send({ type: 'offer', sdp: pc.localDescription.sdp });
  const answer = await next();
  await pc.setRemoteDescription({ type: 'answer', sdp: answer.sdp });
}

/** Dart offers; browser answers and trickles candidates. */
async function answerDart(pc) {
  const offer = await next();
  await pc.setRemoteDescription({ type: 'offer', sdp: offer.sdp });
  await pc.setLocalDescription(await pc.createAnswer());
  send({ type: 'answer', sdp: pc.localDescription.sdp });
}

/** DTLS version and cipher the browser negotiated, from getStats. */
async function dtlsSummary(pc) {
  const stats = await pc.getStats();
  for (const s of stats.values()) {
    if (s.type === 'transport') return `tls ${s.tlsVersion ?? '?'} ${s.dtlsCipher ?? '?'} role ${s.dtlsRole ?? '?'}`;
  }
  return 'no transport stats';
}

const opened = (dc) => new Promise((r) => (dc.readyState === 'open' ? r() : (dc.onopen = r)));

/** Sends each message and checks the echo matches. */
async function echoRoundTrip(dc, messages) {
  dc.binaryType = 'arraybuffer';
  const replies = [];
  const done = new Promise((resolve) => {
    dc.onmessage = (e) => {
      replies.push(new Uint8Array(e.data));
      if (replies.length === messages.length) resolve();
    };
  });
  for (const m of messages) dc.send(m);
  await done;
  return messages.every((m, i) => equal(m, replies[i]));
}

/** Sends `total` pattern bytes in chunks, honoring bufferedAmount. */
async function sendBulk(dc, total, chunk) {
  dc.bufferedAmountLowThreshold = 256 * 1024;
  for (let offset = 0; offset < total; offset += chunk) {
    if (dc.bufferedAmount > 1024 * 1024) {
      await new Promise((r) => (dc.onbufferedamountlow = r));
    }
    dc.send(pattern(offset, Math.min(chunk, total - offset)));
  }
}

const scenarios = {
  // Browser offers, opens an in-band channel, Dart echoes.
  async 'browser-offers-echo'() {
    const pc = newPeer();
    const dc = pc.createDataChannel('echo');
    await offerToDart(pc);
    await opened(dc);
    const sizes = [1, 100, 1024, 16 * 1024];
    const ok = await echoRoundTrip(dc, sizes.map((n, i) => pattern(i * 100000, n)));
    report(ok, `sizes ${sizes}; ${await dtlsSummary(pc)}`);
  },

  // Dart offers and opens the channel; the browser echoes. Dart decides.
  async 'dart-offers-echo'() {
    const pc = newPeer();
    pc.ondatachannel = (e) => {
      const dc = e.channel;
      dc.binaryType = 'arraybuffer';
      dc.onmessage = (m) => dc.send(m.data);
    };
    await answerDart(pc);
  },

  // Pre-negotiated stream 0 on both sides (libp2p /webrtc-direct Noise channel).
  async 'negotiated-stream-0'() {
    const pc = newPeer();
    const dc = pc.createDataChannel('', { negotiated: true, id: 0 });
    await offerToDart(pc);
    await opened(dc);
    report(await echoRoundTrip(dc, [new Uint8Array([1, 2, 3])]), `id ${dc.id}`);
  },

  // 4 MiB browser → Dart; Dart verifies and replies with the byte count.
  async 'bulk-browser-to-dart'() {
    const pc = newPeer();
    const dc = pc.createDataChannel('bulk');
    dc.binaryType = 'arraybuffer';
    await offerToDart(pc);
    await opened(dc);
    const reply = new Promise((r) => (dc.onmessage = (e) => r(new TextDecoder().decode(e.data))));
    const started = performance.now();
    await sendBulk(dc, 4 * 1024 * 1024, 16 * 1024);
    const answer = await reply;
    const seconds = (performance.now() - started) / 1000;
    report(answer === 'ok 4194304', `${answer} in ${seconds.toFixed(2)} s`);
  },

  // 4 MiB Dart → browser; the browser verifies the pattern.
  async 'bulk-dart-to-browser'() {
    const pc = newPeer();
    const dc = pc.createDataChannel('bulk');
    dc.binaryType = 'arraybuffer';
    let offset = 0;
    let ok = true;
    const total = 4 * 1024 * 1024;
    const done = new Promise((resolve) => {
      dc.onmessage = (e) => {
        const chunk = new Uint8Array(e.data);
        if (ok && !equal(chunk, pattern(offset, chunk.length))) ok = false;
        offset += chunk.length;
        if (offset >= total) resolve();
      };
    });
    await offerToDart(pc);
    await opened(dc);
    dc.send(new TextEncoder().encode('go'));
    await done;
    report(ok && offset === total, `received ${offset} bytes`);
  },

  // 16 channels opened by the browser, each echoed by Dart.
  async 'many-channels'() {
    const pc = newPeer();
    const channels = Array.from({ length: 16 }, (_, i) => pc.createDataChannel(`ch${i}`));
    await offerToDart(pc);
    await Promise.all(channels.map(opened));
    const results = await Promise.all(channels.map((dc, i) => echoRoundTrip(dc, [pattern(i * 1000, 512)])));
    report(results.every(Boolean), `${results.filter(Boolean).length}/16 echoed`);
  },

  // Dart closes the channel; the browser must see it close.
  async 'dart-closes-channel'() {
    const pc = newPeer();
    const dc = pc.createDataChannel('closing');
    await offerToDart(pc);
    await opened(dc);
    const closed = new Promise((r) => (dc.onclose = r));
    dc.send(new TextEncoder().encode('close please'));
    await closed;
    report(dc.readyState === 'closed', `readyState ${dc.readyState}`);
  },
};

ws.onopen = async () => {
  try {
    await scenarios[scenario]();
  } catch (e) {
    console.log(`error: ${e?.stack ?? e}`);
    report(false, String(e));
  }
};
