// The programs in example/ run, and the code samples in doc/ match them
// (tool/embed_examples.dart), so the guides only show code that works.
import 'dart:io';

import 'package:dart_libp2p_webrtc/interop.dart';
import 'package:test/test.dart';

import '../tool/embed_examples.dart' as embed;

Future<ProcessResult> _run(List<String> args) =>
    Process.run(Platform.resolvedExecutable, ['run', ...args]).timeout(const Duration(minutes: 2));

void main() {
  test('doc samples match the programs they come from', () {
    expect(embed.embedAll(check: true), isEmpty, reason: 'run dart run tool/embed_examples.dart');
  });

  test('example/data_channel.dart', () async {
    final result = await _run(['example/data_channel.dart']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect('${result.stdout}', contains('bob got: hello'));
    expect('${result.stdout}', contains('bob got: how are you?'));
  });

  test('example/example.dart through a go relay', () async {
    final missing = await ExternalRelay.unavailable('go');
    if (missing != null) return markTestSkipped(missing);
    final relay = await ExternalRelay.start('go');
    addTearDown(relay.close);

    final result = await _run(['example/example.dart', relay.tcp]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect('${result.stdout}', matches(RegExp(r'direct connection: /ip[46]/.+/udp/\d+/webrtc')));
    expect('${result.stdout}', contains('hello from'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
