import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:logging/logging.dart';

import '../ffi/rtc_peer_connection.dart';
import '../ffi/rtc_runtime.dart';
import 'pb.dart';
import 'webrtc_conn.dart';

final _log = Logger('WebRtcSignaling');

/// Protocol id of the signaling stream (spec: webrtc.md).
const signalingProtocol = '/webrtc-signaling/0.0.1';

/// Thrown when the SDP exchange or ICE fails.
class WebRtcSignalingException implements Exception {
  final String message;

  WebRtcSignalingException(this.message);

  @override
  String toString() => 'WebRtcSignalingException: $message';
}

/// Runs the offering side ("A" in the spec) over [stream], an outbound
/// `/webrtc-signaling/0.0.1` stream on an authenticated (e.g. relayed)
/// connection to the peer. Returns the established connection.
///
/// Our SDP carries all local candidates (no trickle; see DESIGN.md §2.1);
/// the remote's trickled candidates are applied as they arrive.
Future<WebRtcConn> initiateWebRtc(
  P2PStream stream, {
  RtcConfig config = const RtcConfig(),
  Duration timeout = const Duration(seconds: 30),
}) async {
  final signaling = _SignalingChannel(stream);
  final pc = RtcPeerConnection(config);
  try {
    // Gives the offer an application section to gather candidates for.
    final init = pc.createDataChannel(initChannelLabel);
    await signaling.write(SignalingMessage(SignalingType.sdpOffer, await pc.createOffer()));

    final answer = await signaling.read().timeout(timeout);
    if (answer?.type != SignalingType.sdpAnswer) {
      throw WebRtcSignalingException('expected SDP answer, got ${answer?.type.name ?? 'end of stream'}');
    }
    pc.setRemoteDescription(answer!.data, 'answer');
    await _applyCandidatesUntilConnected(pc, signaling, timeout);

    // Spec: close `init`, waiting for it to close so its id isn't reused
    // early, then close the signaling stream.
    await init.opened.timeout(const Duration(seconds: 10));
    await init.close().timeout(const Duration(seconds: 10), onTimeout: () {});
    await stream.close();
    return await _connFor(pc, stream, Direction.outbound);
  } catch (e) {
    _log.fine('initiator failed: $e');
    await pc.close();
    await stream.reset();
    rethrow;
  }
}

/// Runs the answering side ("B") over [stream], an inbound
/// `/webrtc-signaling/0.0.1` stream. Returns the established connection.
Future<WebRtcConn> answerWebRtc(
  P2PStream stream, {
  RtcConfig config = const RtcConfig(),
  Duration timeout = const Duration(seconds: 30),
}) async {
  final signaling = _SignalingChannel(stream);
  final pc = RtcPeerConnection(config);
  try {
    final offer = await signaling.read().timeout(timeout);
    if (offer?.type != SignalingType.sdpOffer) {
      throw WebRtcSignalingException('expected SDP offer, got ${offer?.type.name ?? 'end of stream'}');
    }
    pc.setRemoteDescription(offer!.data, 'offer');
    await signaling.write(SignalingMessage(SignalingType.sdpAnswer, await pc.createAnswer()));
    await _applyCandidatesUntilConnected(pc, signaling, timeout);
    unawaited(stream.close().catchError((Object _) {}));
    return await _connFor(pc, stream, Direction.inbound);
  } catch (e) {
    _log.fine('responder failed: $e');
    await pc.close();
    await stream.reset();
    rethrow;
  }
}

/// Applies the remote's trickled candidates until ICE connects. The stream
/// may end first (the remote stops sending once it has connected).
Future<void> _applyCandidatesUntilConnected(
  RtcPeerConnection pc,
  _SignalingChannel signaling,
  Duration timeout,
) async {
  final connected = pc.connected(timeout: timeout);
  var done = false;
  unawaited(() async {
    try {
      while (!done) {
        final message = await signaling.read();
        if (message == null) return;
        if (message.type != SignalingType.iceCandidate) {
          _log.fine('ignoring ${message.type.name} during candidate exchange');
          continue;
        }
        _applyCandidate(pc, message.data);
      }
    } catch (e) {
      if (!done) _log.fine('candidate stream ended: $e');
    }
  }());
  try {
    await connected;
  } on TimeoutException {
    throw WebRtcSignalingException('ICE did not connect within ${timeout.inSeconds} s');
  } on StateError catch (e) {
    throw WebRtcSignalingException('ICE failed: ${e.message}');
  } finally {
    done = true;
  }
}

/// [json] is `RTCIceCandidate.toJSON()`; `null`/empty mark end of candidates.
void _applyCandidate(RtcPeerConnection pc, String json) {
  final Object? init;
  try {
    init = jsonDecode(json);
  } on FormatException {
    _log.fine('ignoring malformed candidate: $json');
    return;
  }
  if (init is! Map<String, dynamic>) return;
  final candidate = init['candidate'];
  if (candidate is! String || candidate.isEmpty) return;
  try {
    pc.addRemoteCandidate(candidate, init['sdpMid'] as String?);
  } on RtcException catch (e) {
    _log.fine('remote candidate rejected ($e): $candidate');
  }
}

Future<WebRtcConn> _connFor(RtcPeerConnection pc, P2PStream signaling, Direction direction) async {
  final relayed = signaling.conn;
  return WebRtcConn(
    peerConnection: pc,
    localPeer: relayed.localPeer,
    remotePeer: relayed.remotePeer,
    remotePublicKey: await relayed.remotePublicKey,
    localMultiaddr: MultiAddr('/webrtc'),
    // The selected candidate's address, not the relay's: the connection is
    // direct, and the swarm treats any /p2p-circuit address as relayed.
    remoteMultiaddr: _webRtcAddr(pc.remoteAddress),
    direction: direction,
  );
}

/// `/ip4|ip6/<ip>/udp/<port>/webrtc` for an `ip:port` from libdatachannel.
MultiAddr _webRtcAddr(String? hostPort) {
  final colon = hostPort?.lastIndexOf(':') ?? -1;
  final ip = colon > 0 ? InternetAddress.tryParse(hostPort!.substring(0, colon)) : null;
  final port = colon > 0 ? int.tryParse(hostPort!.substring(colon + 1)) : null;
  if (ip == null || port == null) return MultiAddr('/webrtc');
  final family = ip.type == InternetAddressType.IPv6 ? 'ip6' : 'ip4';
  return MultiAddr('/$family/${ip.address}/udp/$port/webrtc');
}

/// Varint-length-prefixed [SignalingMessage]s over a libp2p stream.
class _SignalingChannel {
  final P2PStream _stream;
  // SDP is a few KB; allow generous headroom.
  final _decoder = LengthPrefixedDecoder(maxLength: 256 * 1024);
  final _pending = <Uint8List>[];

  _SignalingChannel(this._stream);

  Future<void> write(SignalingMessage message) {
    final body = message.encode();
    return _stream.write((BytesBuilder(copy: false)
          ..add(encodeVarint(body.length))
          ..add(body))
        .takeBytes());
  }

  /// The next message, or null at end of stream.
  Future<SignalingMessage?> read() async {
    while (_pending.isEmpty) {
      final chunk = await _stream.read();
      if (chunk.isEmpty) return null;
      _pending.addAll(_decoder.add(chunk));
    }
    return SignalingMessage.decode(_pending.removeAt(0));
  }
}
