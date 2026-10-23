// The libp2p session against tool/libp2p_hub.dart on a desktop: the hub's
// Dart host and browser dial this phone over /webrtc, then it dials them.
import 'dart:io';

import 'package:dart_libp2p_webrtc/dart_libp2p_webrtc.dart';
import 'package:dart_libp2p_webrtc/interop.dart';
import 'package:flutter/material.dart';

const _defaultHub = String.fromEnvironment('LIBP2P_HUB');

class Libp2pSection extends StatefulWidget {
  /// ICE servers to use (e.g. STUN), from the page's switch.
  final List<String> iceServers;

  /// Called with the report text whenever it changes, for the copy button.
  final ValueChanged<String> onReport;

  const Libp2pSection({super.key, required this.iceServers, required this.onReport});

  @override
  State<Libp2pSection> createState() => _Libp2pSectionState();
}

class _Libp2pSectionState extends State<Libp2pSection> {
  final _hub = TextEditingController(text: _defaultHub);
  bool _running = false;
  PhoneSessionReport? _report;

  Future<void> _run() async {
    final hub = _hub.text.trim();
    final uri = Uri.tryParse(hub);
    if (!hub.startsWith('/') && (uri == null || !uri.hasAuthority)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter http://host:8788 or <relay>/p2p-circuit/p2p/<hub>')));
      return;
    }
    setState(() {
      _running = true;
      _report = null;
    });
    final label = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    debugPrint('LIBP2P start $label hub=$hub ice=${widget.iceServers}');
    final report = await runPhoneSession(
      hub,
      label: label,
      rtcConfig: RtcConfig(iceServers: widget.iceServers),
      onUpdate: (r) {
        if (mounted) setState(() => _report = r);
        widget.onReport('$r');
      },
    );
    for (final line in '$report'.split('\n')) {
      debugPrint('LIBP2P $line');
    }
    widget.onReport('$report');
    if (!mounted) return;
    setState(() {
      _report = report;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final all = report?.all.toList() ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('libp2p over WebRTC', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _hub,
          enabled: !_running,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'libp2p hub',
            hintText: 'http://192.168.1.10:8788 or <relay>/p2p-circuit/p2p/<hub>',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _running ? null : _run,
          icon: const Icon(Icons.hub),
          label: Text(_running ? 'Running libp2p session…' : 'Run libp2p session'),
        ),
        if (report != null) ...[
          const SizedBox(height: 8),
          Text(
            '${all.where((r) => r.ok).length}/${all.length} ok${report.error == null ? '' : ' — ${report.error}'}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (final MapEntry(key: direction, value: results) in report.sections.entries)
            if (results.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(direction, style: Theme.of(context).textTheme.labelLarge),
              ),
              for (final r in results)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(r.ok ? Icons.check_circle : Icons.error, color: r.ok ? Colors.green : Colors.red),
                  title: Text(r.name),
                  subtitle: Text('${r.elapsed.inMilliseconds} ms · ${r.detail}'),
                ),
            ],
        ],
      ],
    );
  }
}
