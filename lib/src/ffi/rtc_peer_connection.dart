import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart' as rtc;
import 'rtc_data_channel.dart';
import 'rtc_runtime.dart';

/// Peer connection state, matching `rtcState`.
enum RtcPeerState { initial, connecting, connected, disconnected, failed, closed }

/// Peer connection settings.
class RtcConfig {
  /// ICE server URLs, e.g. `stun:stun.l.google.com:19302` or
  /// `turn:user:pass@host:3478` (TURN over UDP; user and password
  /// percent-encoded).
  final List<String> iceServers;

  /// Advertise only TURN relay candidates (`iceTransportPolicy: 'relay'`).
  ///
  /// Unlike in browsers this does not stop ICE from using host sockets:
  /// libdatachannel only leaves the other candidates out of the SDP, so a
  /// peer that sends us its own host candidates can still connect directly
  /// (via peer-reflexive candidates). Only when both sides are relay-only is
  /// the path forced through TURN.
  final bool relayOnly;

  /// Local address to gather host candidates on; null means all interfaces.
  final String? bindAddress;

  /// UDP port range for ICE; 0 means automatic.
  final int portRangeBegin;
  final int portRangeEnd;

  /// Largest message accepted from the remote side; 0 means the
  /// libdatachannel default.
  final int maxMessageSize;

  const RtcConfig({
    this.iceServers = const [],
    this.relayOnly = false,
    this.bindAddress,
    this.portRangeBegin = 0,
    this.portRangeEnd = 0,
    this.maxMessageSize = 0,
  });
}

/// A libdatachannel peer connection with negotiation driven explicitly.
///
/// Our side does not trickle: [createOffer] and [createAnswer] complete once
/// ICE gathering has finished, and return SDP with every local candidate in
/// it. Remote candidates can still be trickled in with [addRemoteCandidate].
class RtcPeerConnection {
  final int id;

  RtcPeerState _state = RtcPeerState.initial;
  final _states = StreamController<RtcPeerState>.broadcast();
  final _incoming = StreamController<RtcDataChannel>();
  final _channels = <int, RtcDataChannel>{};
  bool _gatheringComplete = false;
  Completer<void>? _gathered;
  bool _closed = false;

  RtcPeerConnection._(this.id) {
    RtcRuntime.instance.registerPeerConnection(
      id,
      PcCallbacks(
        onStateChange: (state) => _setState(RtcPeerState.values[state]),
        onGatheringStateChange: _onGatheringStateChange,
        onDataChannel: _onDataChannel,
      ),
    );
  }

  factory RtcPeerConnection([RtcConfig config = const RtcConfig()]) {
    final id = using((arena) {
      final c = arena<rtc.rtcConfiguration>();
      final servers = arena<Pointer<Char>>(config.iceServers.length);
      for (var i = 0; i < config.iceServers.length; i++) {
        servers[i] = config.iceServers[i].toNativeUtf8(allocator: arena).cast();
      }
      c.ref
        ..iceServers = servers
        ..iceServersCount = config.iceServers.length
        ..bindAddress = config.bindAddress?.toNativeUtf8(allocator: arena).cast() ?? nullptr
        ..disableAutoNegotiation = true
        ..iceTransportPolicy = config.relayOnly
            ? rtc.rtcTransportPolicy.RTC_TRANSPORT_POLICY_RELAY
            : rtc.rtcTransportPolicy.RTC_TRANSPORT_POLICY_ALL
        ..portRangeBegin = config.portRangeBegin
        ..portRangeEnd = config.portRangeEnd
        ..maxMessageSize = config.maxMessageSize;
      return check('rtcCreatePeerConnection', rtc.rtcCreatePeerConnection(c));
    });
    return RtcPeerConnection._(id);
  }

  RtcPeerState get state => _state;

  Stream<RtcPeerState> get onStateChange => _states.stream;

  /// Data channels opened by the remote side. Buffered until listened to.
  Stream<RtcDataChannel> get onDataChannel => _incoming.stream;

  /// Completes when connected; errors if the connection fails or closes
  /// first, or after [timeout].
  Future<void> connected({Duration timeout = const Duration(seconds: 30)}) {
    if (_state == RtcPeerState.connected) return Future.value();
    return onStateChange
        .firstWhere((s) => s == RtcPeerState.connected || s.index >= RtcPeerState.failed.index)
        .timeout(timeout)
        .then((s) {
      if (s != RtcPeerState.connected) {
        throw StateError('Peer connection $id ended in state ${s.name}');
      }
    });
  }

  /// Creates and applies a local offer; returns its SDP.
  Future<String> createOffer() => _setLocalDescription('offer');

  /// Creates and applies a local answer to the remote offer; returns its SDP.
  Future<String> createAnswer() => _setLocalDescription('answer');

  /// [type] is `offer` or `answer`.
  void setRemoteDescription(String sdp, String type) {
    using((arena) => check(
        'rtcSetRemoteDescription',
        rtc.rtcSetRemoteDescription(id, sdp.toNativeUtf8(allocator: arena).cast(),
            type.toNativeUtf8(allocator: arena).cast())));
  }

  void addRemoteCandidate(String candidate, [String? mid]) {
    using((arena) => check(
        'rtcAddRemoteCandidate',
        rtc.rtcAddRemoteCandidate(id, candidate.toNativeUtf8(allocator: arena).cast(),
            mid?.toNativeUtf8(allocator: arena).cast() ?? nullptr)));
  }

  String get localDescription =>
      readNativeString((buf, size) => rtc.rtcGetLocalDescription(id, buf, size));

  /// `ip:port` of the selected remote candidate, once connected.
  String? get remoteAddress {
    final size = rtc.rtcGetRemoteAddress(id, nullptr, 0);
    if (size < 0) return null;
    return readNativeString((buf, size) => rtc.rtcGetRemoteAddress(id, buf, size));
  }

  /// The selected local and remote candidates (SDP `candidate:` lines), once
  /// connected. `typ relay` on either side means the path goes through TURN.
  ({String local, String remote})? get selectedCandidatePair => using((arena) {
        const size = 1024;
        final local = arena<Char>(size);
        final remote = arena<Char>(size);
        if (rtc.rtcGetSelectedCandidatePair(id, local, size, remote, size) < 0) return null;
        return (local: local.cast<Utf8>().toDartString(), remote: remote.cast<Utf8>().toDartString());
      });

  /// Opens a data channel. With [negotiated], both sides must create it with
  /// the same [stream] id and no in-band open handshake is sent.
  RtcDataChannel createDataChannel(
    String label, {
    String protocol = '',
    bool negotiated = false,
    int? stream,
  }) {
    final dc = using((arena) {
      final init = arena<rtc.rtcDataChannelInit>();
      init.ref
        ..protocol = protocol.toNativeUtf8(allocator: arena).cast()
        ..negotiated = negotiated
        ..manualStream = stream != null
        ..stream = stream ?? 0;
      return check(
          'rtcCreateDataChannelEx',
          rtc.rtcCreateDataChannelEx(
              id, label.toNativeUtf8(allocator: arena).cast(), init));
    });
    return _track(dc);
  }

  /// Closes every channel and the connection, and frees the native objects.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    rtc.rtcClosePeerConnection(id);
    for (final channel in _channels.values.toList()) {
      channel.dispose();
    }
    RtcRuntime.instance.unregisterPeerConnection(id);
    rtc.rtcDeletePeerConnection(id);
    _setState(RtcPeerState.closed);
    _gathered?.completeError(StateError('Peer connection $id closed'));
    _gathered = null;
    // Not awaited: a close only completes once someone has listened.
    _states.close();
    _incoming.close();
  }

  Future<String> _setLocalDescription(String type) async {
    // Gathering only runs once per connection; later descriptions (none in
    // libp2p's single offer/answer exchange) reuse the gathered candidates.
    final gathered = _gatheringComplete ? null : (_gathered ??= Completer<void>());
    using((arena) => check('rtcSetLocalDescription',
        rtc.rtcSetLocalDescription(id, type.toNativeUtf8(allocator: arena).cast())));
    await gathered?.future;
    return localDescription;
  }

  RtcDataChannel _track(int dc) {
    final channel = RtcDataChannel.attach(dc, onDisposed: (c) => _channels.remove(c.id));
    _channels[dc] = channel;
    return channel;
  }

  void _setState(RtcPeerState state) {
    if (state == _state) return;
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  void _onGatheringStateChange(int state) {
    if (state != rtc.rtcGatheringState.RTC_GATHERING_COMPLETE.value) return;
    _gatheringComplete = true;
    _gathered?.complete();
    _gathered = null;
  }

  void _onDataChannel(int channel) {
    if (_closed) return;
    _incoming.add(_track(channel));
  }
}
