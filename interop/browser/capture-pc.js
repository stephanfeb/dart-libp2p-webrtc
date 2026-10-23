// Records every RTCPeerConnection the page creates, so libp2p-page.js can
// report the selected ICE path. Imported first, before js-libp2p reads the
// global.
export const peerConnections = []

const Native = globalThis.RTCPeerConnection
globalThis.RTCPeerConnection = class extends Native {
  constructor (...args) {
    super(...args)
    peerConnections.push(this)
  }
}

/** Candidate types (host, srflx, prflx, relay) of the connected pc's selected pair. */
export async function selectedPath () {
  for (const pc of peerConnections) {
    if (pc.connectionState !== 'connected') continue
    const stats = await pc.getStats()
    let pair
    for (const s of stats.values()) {
      if (s.type === 'transport' && s.selectedCandidatePairId) pair = stats.get(s.selectedCandidatePairId)
    }
    // Firefox has no transport stats; it marks the pair selected instead.
    if (pair == null) {
      for (const s of stats.values()) {
        if (s.type === 'candidate-pair' && (s.selected || (s.nominated && s.state === 'succeeded'))) pair = s
      }
    }
    if (pair == null) continue
    return {
      local: stats.get(pair.localCandidateId)?.candidateType,
      remote: stats.get(pair.remoteCandidateId)?.candidateType
    }
  }
  return null
}
