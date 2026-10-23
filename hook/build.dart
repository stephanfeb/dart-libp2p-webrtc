// Builds libdatachannel (data channels only, Mbed TLS backend) with CMake and
// bundles it as the code asset `package:dart_libp2p_webrtc/libdatachannel`.
//
// Requires cmake and ninja on PATH. Android additionally needs the NDK that
// Flutter selects (located from the configured C compiler).
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const assetName = 'libdatachannel';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;

    final source = input.packageRoot.resolve('native/');
    final buildDir = input.outputDirectory.resolve('cmake/');
    await Directory.fromUri(buildDir).create(recursive: true);

    await _run('cmake', [
      '-S', source.toFilePath(),
      '-B', buildDir.toFilePath(),
      '-G', 'Ninja',
      '-DCMAKE_BUILD_TYPE=Release',
      ..._platformArgs(code),
    ]);
    await _run('cmake', [
      '--build', buildDir.toFilePath(),
      '--target', 'datachannel',
    ]);

    final libFile = buildDir.resolve(
      'libdatachannel/${code.targetOS.dylibFileName('datachannel')}',
    );
    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: assetName,
      linkMode: DynamicLoadingBundled(),
      file: libFile,
    ));

    // Rebuild when native sources or the superbuild change.
    output.dependencies.addAll([
      source.resolve('CMakeLists.txt'),
      source.resolve('mbedtls_user_config.h'),
      input.packageRoot.resolve('third_party/libdatachannel/include/rtc/rtc.h'),
    ]);
  });
}

List<String> _platformArgs(CodeConfig code) {
  final arch = code.targetArchitecture;
  switch (code.targetOS) {
    case OS.macOS:
      return [
        '-DCMAKE_OSX_ARCHITECTURES=${_appleArch(arch)}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.macOS.targetVersion}',
      ];
    case OS.iOS:
      final simulator = code.iOS.targetSdk == IOSSdk.iPhoneSimulator;
      return [
        '-DCMAKE_SYSTEM_NAME=iOS',
        '-DCMAKE_OSX_SYSROOT=${simulator ? 'iphonesimulator' : 'iphoneos'}',
        '-DCMAKE_OSX_ARCHITECTURES=${_appleArch(arch)}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.iOS.targetVersion}',
      ];
    case OS.android:
      return [
        '-DCMAKE_TOOLCHAIN_FILE=${_ndkRoot(code)}/build/cmake/android.toolchain.cmake',
        '-DANDROID_ABI=${_androidAbi(arch)}',
        '-DANDROID_PLATFORM=android-${code.android.targetNdkApi}',
        '-DANDROID_STL=c++_static',
      ];
    case OS.linux:
      final cc = code.cCompiler;
      return [
        if (cc != null) '-DCMAKE_C_COMPILER=${cc.compiler.toFilePath()}',
        if (cc != null)
          '-DCMAKE_CXX_COMPILER=${cc.compiler.toFilePath().replaceFirst(RegExp(r'clang$'), 'clang++')}',
      ];
    default:
      throw UnsupportedError('dart_libp2p_webrtc: ${code.targetOS} is not supported yet');
  }
}

String _appleArch(Architecture arch) => switch (arch) {
      Architecture.arm64 => 'arm64',
      Architecture.x64 => 'x86_64',
      _ => throw UnsupportedError('Unsupported Apple architecture: $arch'),
    };

String _androidAbi(Architecture arch) => switch (arch) {
      Architecture.arm64 => 'arm64-v8a',
      Architecture.arm => 'armeabi-v7a',
      Architecture.x64 => 'x86_64',
      Architecture.ia32 => 'x86',
      _ => throw UnsupportedError('Unsupported Android architecture: $arch'),
    };

/// The NDK root, from the clang that Flutter configures:
/// `<ndk>/toolchains/llvm/prebuilt/<host>/bin/clang`.
String _ndkRoot(CodeConfig code) {
  final cc = code.cCompiler;
  if (cc == null) {
    throw StateError('Android builds need a C compiler config (the NDK clang)');
  }
  return File.fromUri(cc.compiler).parent.parent.parent.parent.parent.parent.path;
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
}
