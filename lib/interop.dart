/// Browser interop harness: the Dart peer's scenarios, the signaling relay
/// and the Playwright browser driver. Used by test/interop/ on the desktop
/// and by example/interop_app on phones.
library;

export 'src/interop/browser_driver.dart';
export 'src/interop/interop_server.dart';
export 'src/interop/interop_session.dart';
export 'src/interop/nat_check.dart';
export 'src/interop/scenarios.dart';
export 'src/interop/external_relay.dart';
export 'src/interop/libp2p_dialback.dart' show dialBackProtocol, reportProtocol, serveDialBack;
export 'src/interop/libp2p_checks.dart' show CheckResult, createTestHost, echoProtocol, reserveOn, runWebRtcChecks;
export 'src/interop/libp2p_hub.dart';
export 'src/interop/libp2p_phone.dart';
