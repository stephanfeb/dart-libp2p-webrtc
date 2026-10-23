// Characterizes the NAT in front of this machine (mapping behaviour) by asking
// several public STUN servers for our address from one UDP socket.
//
//   dart run tool/nat_check.dart
import 'dart:io';

import 'package:dart_libp2p_webrtc/interop.dart';

Future<void> main() async {
  print('');
  print(await checkNat(family: InternetAddressType.IPv4));
  print(await checkNat(family: InternetAddressType.IPv6));
}
