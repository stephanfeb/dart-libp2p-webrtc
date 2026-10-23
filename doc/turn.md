# Running a TURN server

When two peers have no direct path, for example a phone behind a carrier's
symmetric IPv4 NAT and a browser on an IPv4-only network (see
[Networks](networks.md#what-connects-directly)), WebRTC can only connect
through a TURN server. TURN carries every byte of the connections that use
it, so you either run one or pay for a hosted service.

This guide sets up [coturn](https://github.com/coturn/coturn), the common
open-source TURN server, for Dart apps and browsers. Its configuration and
the credential code below are what the [TURN tests](interop.md) run.

## What the server must offer

| Peer | Uses |
|---|---|
| Dart or Flutter app | **TURN over UDP only** (`turn:` on UDP 3478). libdatachannel's ICE, libjuice, has no TURN over TCP or TLS. |
| Browser | TURN over UDP, and TCP or TLS (`turns:`) if you enable them |

So the server needs UDP 3478 and a range of UDP ports for relay
allocations, open in its firewall. Each relayed peer takes one port from the
range for as long as its connection lasts, so size the range for the
connections you expect at once.

## Configuration

`/etc/coturn/turnserver.conf`:

```ini
listening-port=3478
min-port=49160
max-port=49999
realm=turn.example.com

# Time-limited credentials from a shared secret (see below). Use a long
# random value, and keep it on your backend.
use-auth-secret
static-auth-secret=<long random secret>

fingerprint
no-cli
no-multicast-peers
# No TLS: Dart peers can't use it. See "TLS for browsers" below.
no-tls
no-dtls

# Don't let clients relay into the server's own private networks.
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255

# On a cloud VM whose public address is NATed to a private one (AWS, GCP):
# external-ip=<public ip>/<private ip>

log-file=stdout
```

coturn refuses relaying to loopback by default. The test configuration in
[`docker/coturn/`](../docker/coturn) adds `allow-loopback-peers`, because
its peers run on the same machine; leave it out of a real deployment.

## Running it in Docker

On a Linux server, use host networking:

```yaml
services:
  coturn:
    image: coturn/coturn:latest
    command: ["-c", "/etc/coturn/turnserver.conf"]
    network_mode: host
    volumes:
      - ./turnserver.conf:/etc/coturn/turnserver.conf:ro
    restart: unless-stopped
```

With published ports instead, Docker's NAT sits between coturn and the
peers and rewrites the ports of relayed traffic. In our tests (Docker
Desktop on macOS, which has no host networking), browsers handled that
unevenly: WebKit timed out and Firefox couldn't be dialed. That's why the
test server only serves peers on loopback.

## Credentials

With `use-auth-secret`, coturn accepts any username of the form
`<expiry unix time>:<label>` whose password is the base64 HMAC-SHA1 of the
username with the shared secret. Your backend mints them, and gives them to
the app and the web page, so the secret never ships in either, and leaked
credentials stop working when they expire.

<!-- example: example/turn_credentials.dart#credentials -->
```dart
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
```
<!-- /example -->

`turnCredentials` uses [`package:crypto`](https://pub.dev/packages/crypto);
any language with HMAC-SHA1 does the same on your backend.
`dart run example/turn_credentials.dart turn.example.com <secret>` prints
both forms.

The Dart app takes the URL:

```dart
WebRtcTransport(
  rtcConfig: RtcConfig(iceServers: [
    'stun:stun.l.google.com:19302',
    urlFromBackend, // turnUrl(...) on your backend
  ]),
)
```

The browser takes the username and password as they are, **not**
percent-encoded:

```js
webRTC({
  rtcConfiguration: {
    iceServers: [
      { urls: 'stun:stun.l.google.com:19302' },
      { urls: 'turn:turn.example.com:3478', username, credential }
    ]
  }
})
```

Pick a lifetime that covers how long the app uses them, and fetch new ones
before they expire.

For a quick trial, a fixed user works too: `lt-cred-mech` and
`user=<name>:<password>` instead of `use-auth-secret`, as the tests'
[`turnserver.conf`](../docker/coturn/turnserver.conf) does.

## Checking that it works

Bad credentials don't raise an error on the Dart side: the peer just
gathers no relay candidates, and ICE fails when no direct path exists. So
check that a relay-only offer contains relay candidates:

```dart
final pc = RtcPeerConnection(RtcConfig(iceServers: [turnUrl], relayOnly: true));
pc.createDataChannel('probe');
final offer = await pc.createOffer();
print(offer.contains('typ relay') ? 'TURN works' : 'no relay candidates');
```

No relay candidates means wrong or expired credentials, an unencoded URL,
or UDP 3478 blocked between the peer and the server.

To see a connection actually go through TURN, make both sides relay-only:
`RtcConfig(relayOnly: true)` in Dart (it only filters advertised
candidates, so one relay-only Dart side can still end up direct) and
`iceTransportPolicy: 'relay'` in the browser. Then
`WebRtcConn.selectedCandidatePair` shows `typ relay`
(see [Networks](networks.md#which-path-did-it-take)).

When testing on one machine, Firefox won't use a TURN server on loopback;
Chrome and WebKit do.

## TLS for browsers

Some networks block everything but TCP 443. Browsers on those networks can
still reach TURN over TLS (`turns:turn.example.com:443`) if you give coturn
a certificate (`cert=`, `pkey=`, `tls-listening-port=443`, without
`no-tls`). Dart peers can't use it, so on such a network a Dart app stays
on its relayed libp2p connection (see
[Networks](networks.md#turn-on-the-dart-side-udp-only)).

## What's tested

The TURN tests run coturn in Docker on loopback, with a fixed user and with
time-limited credentials minted by `example/turn_credentials.dart`.
Relay-only Dart peers connect relay to relay. A relay-only browser (Chrome,
WebKit) connects to a Dart host in both directions. Expired and unencoded
credentials give no relay candidates. A hosted TURN server with a phone on
cellular hasn't been measured yet.
