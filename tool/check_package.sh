#!/bin/sh
# Copies the files `dart pub publish` would include (.pubignore uses only
# anchored paths, so rsync excludes match it) to a temporary directory and
# builds the native library there with the package's own hook, proving the
# published sources are complete. Run from the repository root.
set -eu
out=$(mktemp -d)
sed -e '/^#/d' -e '/^$/d' .pubignore | sed 's|/$||' > "$out.excludes"
rsync -a --exclude=.git --exclude-from="$out.excludes" ./ "$out/pkg/"
echo "package tree: $(du -sh "$out/pkg" | cut -f1) in $out/pkg"
# Until dart_libp2p's release is on pub.dev, resolve it as the repository
# does, from the sibling checkout.
if [ -f pubspec_overrides.yaml ]; then
  printf 'dependency_overrides:\n  dart_libp2p:\n    path: %s\n' "$(cd ../dart-libp2p && pwd)" > "$out/pkg/pubspec_overrides.yaml"
fi
cd "$out/pkg"
dart pub get --offline >/dev/null 2>&1 || dart pub get >/dev/null
dart test test/ffi_smoke_test.dart
