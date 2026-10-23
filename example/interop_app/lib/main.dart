// Runs the dart_libp2p_webrtc browser interop scenarios on a phone against a
// browser driven by tool/interop_server.dart on a desktop.
//
//   flutter run --dart-define=INTEROP_SERVER=ws://<desktop-ip>:8787
import 'dart:io';

import 'package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart';
import 'package:dart_libp2p_webrtc/interop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _defaultServer = String.fromEnvironment('INTEROP_SERVER');
const _stunServer = 'stun:stun.l.google.com:19302';

void main() => runApp(const InteropApp());

class InteropApp extends StatelessWidget {
  const InteropApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'WebRTC interop',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
        home: const InteropPage(),
      );
}

class InteropPage extends StatefulWidget {
  const InteropPage({super.key});

  @override
  State<InteropPage> createState() => _InteropPageState();
}

class _InteropPageState extends State<InteropPage> {
  final _server = TextEditingController(text: _defaultServer);
  bool _useStun = false;
  bool _running = false;
  String? _current;
  final _reports = <String, ScenarioReport>{};
  List<NatCheckResult>? _nat;
  bool _checkingNat = false;

  Future<void> _checkNat() async {
    setState(() => _checkingNat = true);
    final results = [
      await checkNat(family: InternetAddressType.IPv4),
      await checkNat(family: InternetAddressType.IPv6),
    ];
    for (final r in results) {
      debugPrint('INTEROP NAT $r');
    }
    if (!mounted) return;
    setState(() {
      _nat = results;
      _checkingNat = false;
    });
  }

  Future<void> _runAll() async {
    final server = Uri.tryParse(_server.text.trim());
    if (server == null || !server.hasAuthority) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter ws://host:port')));
      return;
    }
    final config = RtcConfig(iceServers: _useStun ? const [_stunServer] : const []);
    setState(() {
      _running = true;
      _reports.clear();
    });
    debugPrint('INTEROP start ${Platform.operatingSystem} ${Platform.operatingSystemVersion} '
        'server=$server stun=$_useStun');
    for (final name in scenarios.keys) {
      setState(() => _current = name);
      final report = await runScenario(name, server, config: config);
      debugPrint('INTEROP $report | browser candidates: ${report.browserCandidateTypes.join(', ')}');
      if (!report.ok) {
        for (final c in report.localCandidates) {
          debugPrint('INTEROP   local  $c');
        }
        for (final c in report.browserCandidates) {
          debugPrint('INTEROP   remote $c');
        }
      }
      if (!mounted) return;
      setState(() => _reports[name] = report);
    }
    final passed = _reports.values.where((r) => r.ok).length;
    debugPrint('INTEROP done $passed/${scenarios.length} passed');
    setState(() {
      _running = false;
      _current = null;
    });
  }

  String get _reportText => [
        'dart_libp2p_webrtc interop — ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        'server ${_server.text}, stun $_useStun',
        if (_nat != null) ...['NAT check:', for (final r in _nat!) '$r'],
        for (final r in _reports.values) ...[
          '$r',
          if (r.browserCandidateTypes.isNotEmpty) '  browser candidates: ${r.browserCandidateTypes.join(', ')}',
          if (!r.ok) ...[
            for (final c in r.localCandidates) '  local  $c',
            for (final c in r.browserCandidates) '  remote $c',
          ],
        ],
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    final passed = _reports.values.where((r) => r.ok).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebRTC interop'),
        actions: [
          IconButton(
            tooltip: 'Copy report',
            icon: const Icon(Icons.copy),
            onPressed: _reports.isEmpty && _nat == null
                ? null
                : () => Clipboard.setData(ClipboardData(text: _reportText)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _server,
            enabled: !_running,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Interop server',
              hintText: 'ws://192.168.1.10:8787',
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use STUN'),
            subtitle: const Text(_stunServer),
            value: _useStun,
            onChanged: _running ? null : (v) => setState(() => _useStun = v),
          ),
          FilledButton.icon(
            onPressed: _running ? null : _runAll,
            icon: const Icon(Icons.play_arrow),
            label: Text(_running ? 'Running $_current…' : 'Run all scenarios'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _running || _checkingNat ? null : _checkNat,
            icon: const Icon(Icons.router),
            label: Text(_checkingNat ? 'Checking NAT…' : 'Check NAT'),
          ),
          if (_nat != null)
            Card(
              margin: const EdgeInsets.only(top: 12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _nat!.join('\n\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          if (_reports.isNotEmpty && !_running)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('$passed/${scenarios.length} passed', style: Theme.of(context).textTheme.titleMedium),
            ),
          const SizedBox(height: 8),
          for (final name in scenarios.keys) _ScenarioTile(name: name, report: _reports[name], running: _current == name),
        ],
      ),
    );
  }
}

class _ScenarioTile extends StatelessWidget {
  final String name;
  final ScenarioReport? report;
  final bool running;

  const _ScenarioTile({required this.name, required this.report, required this.running});

  @override
  Widget build(BuildContext context) {
    final r = report;
    final Widget leading = running
        ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
        : r == null
            ? const Icon(Icons.radio_button_unchecked)
            : Icon(r.ok ? Icons.check_circle : Icons.error, color: r.ok ? Colors.green : Colors.red);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: Text(name),
      subtitle: r == null
          ? null
          : Text([
              '${r.elapsed.inMilliseconds} ms${r.remoteAddress == null ? '' : ' via ${r.remoteAddress}'}',
              r.detail,
              if (r.browserCandidateTypes.isNotEmpty) 'browser: ${r.browserCandidateTypes.toSet().join(', ')}',
            ].join('\n')),
      isThreeLine: r != null,
    );
  }
}
