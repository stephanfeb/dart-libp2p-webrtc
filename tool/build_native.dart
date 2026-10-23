// Triggers the build hook (libdatachannel) without running anything else:
//   dart run tool/build_native.dart
import 'package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart';

void main() {
  // Touching the runtime loads the native library and proves it links.
  RtcRuntime.enableNativeLogging(RtcLogLevel.none);
  print('libdatachannel loaded');
}
