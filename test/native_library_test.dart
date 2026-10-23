// The native library must be one self-contained file: the Dart and Flutter
// bundlers ship only it, so any other non-system library it links (once,
// Mbed TLS's everest and p256m) fails to load on the device.
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('libdatachannel links only system libraries', () async {
    // Built by the package's hook before the tests run.
    final library = File('.dart_tool/lib/libdatachannel.dylib');
    expect(library.existsSync(), isTrue, reason: 'run any FFI test first to build it');
    final result = await Process.run('otool', ['-L', library.path]);
    final dependencies = '${result.stdout}'
        .split('\n')
        .skip(2) // the file name and the library's own install name
        .map((line) => line.trim().split(' ').first)
        .where((name) => name.isNotEmpty);
    expect(dependencies, everyElement(anyOf(startsWith('/usr/lib/'), startsWith('/System/'))));
  });
}
