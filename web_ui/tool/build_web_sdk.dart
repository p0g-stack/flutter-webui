// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// Builds the patched Flutter web SDK.
///
/// Applies `web_ui/patches/*.patch` to the web engine sources of a Flutter
/// checkout at the pinned release (`web_ui/VERSION`), rewrites them into SDK
/// libraries with the engine's own `sdk_rewriter.dart`, and compiles the
/// platform kernels and DDC modules with the Dart SDK's `kernel_worker` and
/// `dartdevc`, as the engine's `web_sdk/BUILD.gn` does with a prebuilt Dart
/// SDK. No engine build or GN checkout is needed.
///
/// The result mirrors `<flutter>/bin/cache`: `flutter_web_sdk/` (what web
/// builds compile against) and `pkg/sky_engine/lib/ui_web/` (what the analyzer
/// reads for `dart:ui_web`). Overlay it on `bin/cache` (flutter_p0g's
/// precache does this).
///
/// ```
/// dart run web_ui/tool/build_web_sdk.dart --flutter <flutter root> --out <dir>
/// ```
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'flutter',
      help: 'Flutter SDK root at the pinned release.',
      mandatory: true,
    )
    ..addOption('out', help: 'Output directory (replaced).', mandatory: true)
    ..addFlag(
      'ddc',
      help: 'Also build the DDC modules used by debug builds.',
      defaultsTo: true,
    );
  final args = parser.parse(arguments);
  final flutter = p.absolute(args.option('flutter')!);
  final outRoot = p.absolute(args.option('out')!);
  final out = p.join(outRoot, 'flutter_web_sdk');
  final here = p.dirname(p.dirname(p.fromUri(Platform.script)));

  final pinned = File(p.join(here, 'VERSION')).readAsStringSync().trim();
  final version = _flutterVersion(flutter);
  if (version != pinned) {
    _fail('Flutter at $flutter is $version; the patches are for $pinned.');
  }

  final cache = p.join(flutter, 'bin', 'cache');
  final dartSdk = p.join(cache, 'dart-sdk');
  final stockSdk = p.join(cache, 'flutter_web_sdk');
  if (!Directory(p.join(stockSdk, 'kernel')).existsSync()) {
    _fail('No web SDK in $stockSdk; run `flutter precache --web` first.');
  }

  final work = Directory.systemTemp.createTempSync('flutter_webui_sdk');
  try {
    // 1. Patched copy of the web engine sources.
    final engineRel = p.join('engine', 'src', 'flutter');
    final webUiRel = p.join(engineRel, 'lib', 'web_ui');
    await _run('cp', [
      '-R',
      p.join(flutter, webUiRel, 'lib'),
      p.join(work.path, 'lib'),
    ]);
    final staging = p.join(work.path, 'tree');
    Directory(p.join(staging, webUiRel)).createSync(recursive: true);
    await _run('mv', [
      p.join(work.path, 'lib'),
      p.join(staging, webUiRel, 'lib'),
    ]);
    final patches =
        Directory(p.join(here, 'patches'))
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.patch'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final patch in patches) {
      stdout.writeln('apply ${p.basename(patch.path)}');
      await _run('git', [
        'apply',
        '--whitespace=nowarn',
        patch.path,
      ], cwd: staging);
    }

    // 2. Output starts as a copy of the stock web SDK (CanvasKit, flutter.js,
    //    third-party libraries), then the engine libraries are regenerated.
    if (Directory(outRoot).existsSync()) {
      Directory(outRoot).deleteSync(recursive: true);
    }
    Directory(outRoot).createSync(recursive: true);
    await _run('cp', ['-R', stockSdk, out]);
    final lib = p.join(staging, webUiRel, 'lib');
    final rewriter = p.join(flutter, engineRel, 'web_sdk', 'sdk_rewriter.dart');
    final packages = p.join(here, '..', '.dart_tool', 'package_config.json');
    Future<void> rewrite(String outDir, List<String> extra) async {
      final target = p.join(out, 'lib', outDir);
      if (Directory(target).existsSync()) {
        Directory(target).deleteSync(recursive: true);
      }
      await _run(p.join(dartSdk, 'bin', 'dart'), [
        '--packages=$packages',
        rewriter,
        '--output-dir=$target/',
        '--build-dir=${work.path}',
        '--stamp=${p.join(work.path, '$outDir.stamp')}',
        '--depfile=${p.join(work.path, '$outDir.d')}',
        ...extra,
      ]);
    }

    stdout.writeln('rewrite sources');
    await rewrite('ui', [
      '--ui',
      '--input-dir=$lib/',
      '--exclude-pattern=${p.join(lib, 'src')}',
    ]);
    await rewrite('ui_web', [
      '--library-name=ui_web',
      '--public',
      '--api-file=${p.join(lib, 'ui_web', 'src', 'ui_web.dart')}',
      '--input-dir=${p.join(lib, 'ui_web', 'src', 'ui_web')}/',
    ]);
    await rewrite('_engine', [
      '--library-name=engine',
      '--api-file=${p.join(lib, 'src', 'engine.dart')}',
      '--input-dir=${p.join(lib, 'src', 'engine')}/',
      '--exclude-pattern=${p.join(lib, 'src', 'engine', 'skwasm')}',
    ]);
    await rewrite('_skwasm_stub', [
      '--library-name=skwasm_stub',
      '--api-file=${p.join(lib, 'src', 'engine', 'skwasm', 'skwasm_stub.dart')}',
      '--input-dir=${p.join(lib, 'src', 'engine', 'skwasm', 'skwasm_stub')}/',
    ]);
    await rewrite('_skwasm_impl', [
      '--library-name=skwasm_impl',
      '--api-file=${p.join(lib, 'src', 'engine', 'skwasm', 'skwasm_impl.dart')}',
      '--input-dir=${p.join(lib, 'src', 'engine', 'skwasm', 'skwasm_impl')}/',
    ]);

    // 3. Platform kernels.
    final runtime = p.join(dartSdk, 'bin', 'dartaotruntime');
    final kernelWorker = p.join(
      dartSdk,
      'bin',
      'snapshots',
      'kernel_worker_aot.dart.snapshot',
    );
    final roots = [
      '--multi-root-scheme',
      'org-dartlang-sdk',
      '--multi-root',
      'file://$out',
      '--multi-root',
      'file://$cache',
    ];
    Future<void> platform(
      String target,
      String output, {
      required bool summary,
    }) async {
      stdout.writeln('compile kernel/$output');
      await _run(runtime, [
        kernelWorker,
        summary ? '--summary-only' : '--no-summary-only',
        if (!summary) '--null-environment',
        if (target == 'ddc') '--include-unsupported-platform-library-stubs',
        '--target',
        target,
        ...roots,
        '--libraries-file',
        'org-dartlang-sdk:///libraries.json',
        '--output',
        p.join(out, 'kernel', output),
        '--source',
        'dart:core',
        '--source',
        'dart:ui',
        '--source',
        'dart:ui_web',
        '--source',
        'dart:_engine',
        '--source',
        target == 'dart2wasm' ? 'dart:_skwasm_impl' : 'dart:_skwasm_stub',
        '--source',
        'dart:_web_locale_keymap',
      ]);
    }

    await platform('dart2js', 'dart2js_platform.dill', summary: false);
    await platform('dart2wasm', 'dart2wasm_platform.dill', summary: false);
    await platform('ddc', 'ddc_outline.dill', summary: true);

    // 4. DDC modules for debug builds.
    if (args.flag('ddc')) {
      final dartdevc = p.join(
        dartSdk,
        'bin',
        'snapshots',
        'dartdevc_aot.dart.snapshot',
      );
      for (final (prefix, format, canary) in [
        ('amd', 'amd', false),
        ('ddcLibraryBundle', 'ddc', true),
      ]) {
        final js = p.join(out, 'kernel', '$prefix-canvaskit', 'dart_sdk.js');
        stdout.writeln('compile kernel/$prefix-canvaskit/dart_sdk.js');
        await _run(runtime, [
          dartdevc,
          '--compile-sdk',
          'dart:core',
          'dart:ui',
          'dart:ui_web',
          'dart:_engine',
          'dart:_skwasm_stub',
          'dart:_web_locale_keymap',
          '--no-summarize',
          ...roots.sublist(0, 4),
          '--multi-root-output-path',
          out,
          '--multi-root',
          'file://$cache',
          '--libraries-file',
          'org-dartlang-sdk:///libraries.json',
          '--inline-source-map',
          '-DFLUTTER_WEB_USE_SKIA=true',
          '--modules',
          format,
          if (canary) '--canary',
          '-o',
          js,
        ]);
      }
    }

    // 5. The analyzer's copy of dart:ui_web.
    final skyUiWeb = p.join(outRoot, 'pkg', 'sky_engine', 'lib', 'ui_web');
    Directory(p.dirname(skyUiWeb)).createSync(recursive: true);
    await _run('cp', ['-R', p.join(out, 'lib', 'ui_web'), skyUiWeb]);

    File(p.join(out, 'flutter_webui.stamp')).writeAsStringSync(
      'flutter $pinned\n${patches.map((f) => p.basename(f.path)).join('\n')}\n',
    );
    stdout.writeln('patched web SDK: $outRoot');
  } finally {
    work.deleteSync(recursive: true);
  }
}

String _flutterVersion(String flutter) {
  final file = File(p.join(flutter, 'bin', 'cache', 'flutter.version.json'));
  if (file.existsSync()) {
    final match = RegExp(r'"frameworkVersion"\s*:\s*"([^"]+)"')
        .firstMatch(file.readAsStringSync());
    if (match != null) return match.group(1)!;
  }
  final version = File(p.join(flutter, 'version'));
  return version.existsSync() ? version.readAsStringSync().trim() : 'unknown';
}

Future<void> _run(String exe, List<String> args, {String? cwd}) async {
  final result = await Process.run(exe, args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    _fail('$exe ${args.join(' ')}\n${result.stdout}${result.stderr}');
  }
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
