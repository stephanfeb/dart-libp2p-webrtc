/// libp2p WebRTC transport for dart-libp2p, built on libdatachannel.
///
/// Currently exposes the FFI layer only; the libp2p transport is next (see
/// DESIGN.md).
library;

export 'src/ffi/rtc_data_channel.dart' show RtcDataChannel;
export 'src/ffi/rtc_peer_connection.dart' show RtcConfig, RtcPeerConnection, RtcPeerState;
export 'src/ffi/rtc_runtime.dart' show RtcException, RtcLogLevel, RtcRuntime;
