import 'dart:async';
import 'dart:io';

/// Pairs a Dart peer with a browser page and relays their signaling.
///
/// Serves the test page (`/`, `/page.js`) and `/signal`. A Dart peer connects
/// with `role=dart&scenario=…&run=…`; the server then asks [openPage] to load
/// the page for that run, whose WebSocket (`role=browser`) is paired with it.
/// Messages are forwarded verbatim in both directions; whichever side closes
/// first closes the other.
class InteropServer {
  final HttpServer _server;
  final File _pageScript;
  final void Function(Uri pageUrl) _openPage;
  final _runs = <String, _Run>{};

  InteropServer._(this._server, this._pageScript, this._openPage) {
    _server.listen(_handle);
  }

  /// [openPage] receives a URL on loopback; the browser must run on this host.
  static Future<InteropServer> start({
    required File pageScript,
    required void Function(Uri pageUrl) openPage,
    Object? address,
    int port = 0,
  }) async {
    final server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    return InteropServer._(server, pageScript, openPage);
  }

  int get port => _server.port;

  Future<void> close() async {
    for (final run in _runs.values) {
      await run.close();
    }
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    switch (request.uri.path) {
      case '/signal':
        await _signal(request);
      case '/page.js':
        request.response.headers.contentType = ContentType('text', 'javascript', charset: 'utf-8');
        await request.response.addStream(_pageScript.openRead());
        await request.response.close();
      default:
        request.response.headers.contentType = ContentType.html;
        request.response.write('<!doctype html><script type="module" src="/page.js"></script>');
        await request.response.close();
    }
  }

  Future<void> _signal(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final role = params['role'];
    final run = params['run'];
    final scenario = params['scenario'];
    if ((role != 'dart' && role != 'browser') || run == null || scenario == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(request);
    final pair = _runs.putIfAbsent(run, () => _Run(() => _runs.remove(run)));
    if (role == 'dart') {
      pair.attachDart(ws);
      _openPage(Uri(scheme: 'http', host: '127.0.0.1', port: port, path: '/', queryParameters: {
        'scenario': scenario,
        'run': run,
        if (params['ice'] case final ice?) 'ice': ice,
      }));
    } else {
      pair.attachBrowser(ws);
    }
  }
}

/// One Dart ↔ browser pairing. Messages wait in a queue until the other side
/// has connected.
class _Run {
  final void Function() _onClosed;
  WebSocket? _dart;
  WebSocket? _browser;
  final _toDart = <Object>[];
  final _toBrowser = <Object>[];
  bool _closed = false;

  _Run(this._onClosed);

  void attachDart(WebSocket ws) {
    _dart = ws;
    _toDart.forEach(ws.add);
    _toDart.clear();
    ws.listen(_forwardToBrowser, onDone: close, onError: (_) => close());
  }

  void attachBrowser(WebSocket ws) {
    _browser = ws;
    _toBrowser.forEach(ws.add);
    _toBrowser.clear();
    ws.listen(_forwardToDart, onDone: close, onError: (_) => close());
  }

  void _forwardToBrowser(dynamic message) =>
      _browser != null ? _browser!.add(message) : _toBrowser.add(message as Object);

  void _forwardToDart(dynamic message) => _dart != null ? _dart!.add(message) : _toDart.add(message as Object);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _onClosed();
    await _dart?.close();
    await _browser?.close();
  }
}
