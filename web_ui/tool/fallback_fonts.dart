// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// Bundles `web_ui`'s fallback fonts so a WebUI module renders offline.
///
/// `web_ui` loads Roboto and its Noto fallbacks as bytes from
/// `fontFallbackBaseUrl` (the bootstrap sets `fonts/`) at the same paths as on
/// fonts.gstatic.com; a manager WebView exposes no system fonts. This copies
/// the files the pinned Flutter release can ask for into `<webroot>/fonts/`,
/// byte for byte, through a download cache. See `docs/parity.md` (Fonts).
///
/// Sets:
/// - default: Roboto, Noto Sans, Noto Color Emoji, Noto Sans Symbols and
///   Symbols 2, Noto Sans Math (about 2.9 MiB).
/// - `--locales ja,zh-TW,...`: adds the CJK families `web_ui` picks for those
///   locales (about 2.3 MiB each).
/// - `--all`: every file (about 21 MiB).
///
/// ```
/// dart run web_ui/tool/fallback_fonts.dart --flutter <flutter root> \
///     --out <webroot>/fonts [--locales ja] [--all] [--list]
/// ```
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

/// Where `web_ui` downloads from by default (`configuration.dart`).
const String gstatic = 'https://fonts.gstatic.com/s/';

/// Families bundled by default.
const Set<String> defaultFamilies = {
  'Roboto',
  'Noto Sans',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'Noto Sans Symbols 2',
  'Noto Sans Math',
};

/// `web_ui`'s `_kLanguageFontPreferences` (`font_fallback_service.dart`),
/// with the fallbacks it ranks after them.
const Map<String, List<String>> cjkFamilies = {
  'zh-Hant': ['Noto Sans TC'],
  'zh-TW': ['Noto Sans TC'],
  'zh-MO': ['Noto Sans TC'],
  'zh-HK': ['Noto Sans HK', 'Noto Sans TC'],
  'ja': ['Noto Sans JP'],
  'ko': ['Noto Sans KR'],
  'zh': ['Noto Sans SC'],
  'zh-Hans': ['Noto Sans SC'],
  'zh-CN': ['Noto Sans SC', 'Noto Sans TC'],
};

/// A font file: its family and its path under the base URL.
typedef FontFile = ({String family, String path});

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('flutter', help: 'Flutter SDK root.', mandatory: true)
    ..addOption('out', help: 'Output directory (<webroot>/fonts).')
    ..addMultiOption('locales', help: 'Locales whose CJK fonts to add.')
    ..addFlag('all', help: 'Every fallback font.', negatable: false)
    ..addFlag('list', help: 'Print the selected files only.', negatable: false)
    ..addOption(
      'cache',
      help: 'Download cache.',
      defaultsTo: p.join(
        Platform.environment['HOME'] ?? Directory.systemTemp.path,
        '.cache',
        'flutter_webui',
        'fonts',
      ),
    );
  final args = parser.parse(arguments);
  final engine = p.join(
    p.absolute(args.option('flutter')!),
    'engine/src/flutter/lib/web_ui/lib/src/engine',
  );
  final all = readFontFiles(engine);
  final selected = selectFonts(
    all,
    locales: args.multiOption('locales'),
    everything: args.flag('all'),
  );

  if (args.flag('list')) {
    for (final f in selected) {
      stdout.writeln('${f.path}\t${f.family}');
    }
    return;
  }
  final out = args.option('out');
  if (out == null) _fail('--out is required unless --list is given.');

  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  var bytes = 0;
  try {
    for (final f in selected) {
      final cached = File(p.join(args.option('cache')!, f.path));
      if (!cached.existsSync() || cached.lengthSync() == 0) {
        stdout.writeln('fetch ${f.path}');
        await _download(client, Uri.parse(gstatic).resolve(f.path), cached);
      }
      final target = File(p.join(out, f.path));
      target.parent.createSync(recursive: true);
      cached.copySync(target.path);
      bytes += target.lengthSync();
    }
  } finally {
    client.close();
  }
  final mib = (bytes / (1 << 20)).toStringAsFixed(2);
  stdout.writeln('${selected.length} font files, $mib MiB in $out');
}

/// Reads the fallback list and the Roboto path from the engine sources.
List<FontFile> readFontFiles(String engineDir) {
  final data = File(p.join(engineDir, 'font_fallback_data.dart'))
      .readAsStringSync();
  final files = [
    for (final m in RegExp(
      r"NotoFont\(\s*'([^']+)',\s*'([^']+)'",
    ).allMatches(data))
      (family: m[1]!.replaceFirst(RegExp(r' \d+$'), ''), path: m[2]!),
  ];
  final fonts = File(p.join(engineDir, 'canvaskit', 'fonts.dart'))
      .readAsStringSync();
  final roboto = RegExp(r"fontFallbackBaseUrl\}(roboto/[^']+\.woff2)")
      .firstMatch(fonts);
  if (files.isEmpty || roboto == null) {
    _fail('Could not read the font list from $engineDir.');
  }
  return [(family: 'Roboto', path: roboto[1]!), ...files];
}

/// The files for the default set plus [locales], or all of them.
List<FontFile> selectFonts(
  List<FontFile> all, {
  List<String> locales = const [],
  bool everything = false,
}) {
  if (everything) return all;
  final families = {...defaultFamilies};
  for (final locale in locales) {
    final tag = locale.replaceAll('_', '-');
    final match =
        cjkFamilies[tag] ?? cjkFamilies[tag.split('-').first] ?? const [];
    families.addAll(match);
  }
  return [
    for (final f in all)
      if (families.contains(f.family)) f,
  ];
}

Future<void> _download(HttpClient client, Uri uri, File to) async {
  for (var attempt = 1; ; attempt++) {
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      to.parent.createSync(recursive: true);
      final tmp = File('${to.path}.tmp');
      await response.pipe(tmp.openWrite());
      if (tmp.lengthSync() == 0) throw HttpException('empty body', uri: uri);
      tmp.renameSync(to.path);
      return;
    } on IOException catch (e) {
      if (attempt == 4) _fail('$uri: $e');
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
    }
  }
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
