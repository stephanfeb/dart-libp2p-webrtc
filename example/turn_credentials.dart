// Credentials for a coturn server that uses time-limited credentials
// (`use-auth-secret`, the "TURN REST API" scheme): your backend mints them
// with the shared secret and hands them to the app and the web page, so the
// secret never ships in either. See doc/turn.md.
//
//   dart run example/turn_credentials.dart <host> <secret> [user]
import 'dart:convert';

import 'package:crypto/crypto.dart';

// #region credentials
/// Credentials that coturn accepts until [ttl] from now, for [user] (any
/// label; coturn only logs it).
({String username, String password}) turnCredentials(String secret, String user,
    {Duration ttl = const Duration(hours: 12)}) {
  final expires = DateTime.now().add(ttl).millisecondsSinceEpoch ~/ 1000;
  final username = '$expires:$user';
  final mac = Hmac(sha1, utf8.encode(secret)).convert(utf8.encode(username));
  return (username: username, password: base64.encode(mac.bytes));
}

/// The `turn:` URL for `RtcConfig.iceServers`. The username has a `:` and
/// the password is base64 (`/`, `+`, `=`), so both are percent-encoded;
/// unencoded, libdatachannel gets no relay candidates and reports no error.
String turnUrl(String host, ({String username, String password}) credentials, {int port = 3478}) =>
    'turn:${Uri.encodeComponent(credentials.username)}:'
    '${Uri.encodeComponent(credentials.password)}@$host:$port';
// #endregion credentials

void main(List<String> args) {
  final credentials = turnCredentials(args[1], args.length > 2 ? args[2] : 'demo');
  // Browsers take the username and password as they are, unencoded.
  final browserIceServer = {
    'urls': 'turn:${args[0]}:3478',
    'username': credentials.username,
    'credential': credentials.password,
  };
  print('Dart:    ${turnUrl(args[0], credentials)}');
  print('browser: ${jsonEncode(browserIceServer)}');
}
