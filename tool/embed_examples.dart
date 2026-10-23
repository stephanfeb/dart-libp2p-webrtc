// Copies runnable programs into the docs in doc/, so every code sample on the
// site is one the test suite runs (test/examples_test.dart, and the browser
// interop tests for interop/browser/libp2p-page.js). Same scheme as js-udx's
// tools/embed-examples.mjs.
//
// In a doc, a marker pair owns the code block between it:
//
//   <!-- example: example/example.dart#host -->
//   ```dart
//   ...replaced on every run...
//   ```
//   <!-- /example -->
//
// Without `#name` the whole file is embedded; with it, the lines between
// `// #region name` and `// #endregion name`. Region marker lines are never
// embedded. The fence language follows the file extension.
//
//   dart run tool/embed_examples.dart [--check]
//     --check  change nothing; exit 1 if a doc is out of date.
import 'dart:io';
import 'dart:math';

final _block = RegExp(r'(<!-- example: ([^#\s]+)(?:#([\w-]+))? -->\n)[\s\S]*?(<!-- /example -->)');
final _regionLine = RegExp(r'^\s*// #(?:end)?region\b');
const _languages = {'.dart': 'dart', '.js': 'js', '.mjs': 'js', '.ts': 'ts', '.yaml': 'yaml', '.go': 'go'};

/// The embeddable text of [file], or of its region [name], dedented.
String excerpt(String file, String? name) {
  final lines = File(file).readAsStringSync().replaceAll('\r\n', '\n').split('\n');
  var body = lines;
  if (name != null) {
    final start = lines.indexWhere((l) => l.trim() == '// #region $name');
    final end = lines.indexWhere((l) => l.trim() == '// #endregion $name');
    if (start < 0 || end < start) throw StateError('$file: no region "$name"');
    body = lines.sublist(start + 1, end);
  }
  body = body.where((l) => !_regionLine.hasMatch(l)).toList();
  while (body.isNotEmpty && body.last.trim().isEmpty) {
    body.removeLast();
  }
  final indent = body.where((l) => l.trim().isNotEmpty).map((l) => l.length - l.trimLeft().length).fold<int?>(
      null, (a, b) => a == null ? b : min(a, b)) ?? 0;
  return body.map((l) => l.length >= indent ? l.substring(indent) : l.trimLeft()).join('\n');
}

/// [markdown] with every example block rewritten.
String embed(String markdown) => markdown.replaceAllMapped(_block, (m) {
      final file = m[2]!;
      final language = _languages[file.substring(file.lastIndexOf('.'))] ?? '';
      return '${m[1]}```$language\n${excerpt(file, m[3])}\n```\n${m[4]}';
    });

/// Docs whose example blocks differ from the programs; rewritten unless [check].
List<String> embedAll({bool check = false}) {
  final stale = <String>[];
  final docs = Directory('doc').listSync().whereType<File>().where((f) => f.path.endsWith('.md')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final doc in docs) {
    final before = doc.readAsStringSync();
    final after = embed(before);
    if (after == before) continue;
    stale.add(doc.path);
    if (!check) doc.writeAsStringSync(after);
  }
  return stale;
}

void main(List<String> args) {
  final check = args.contains('--check');
  final stale = embedAll(check: check);
  if (stale.isEmpty) {
    print('docs are up to date');
  } else if (check) {
    stderr.writeln('out of date (run dart run tool/embed_examples.dart): ${stale.join(', ')}');
    exit(1);
  } else {
    print('updated ${stale.join(', ')}');
  }
}
