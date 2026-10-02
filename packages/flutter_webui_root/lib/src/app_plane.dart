// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:io';

/// The foreground service in the module's app plane app (webui-termux-api
/// webui.7 and later) that keeps the app unfrozen while the root channel
/// runs. The package is [appPlanePackage].
const String appPlaneServiceClass = 'com.termux.api.RootHelperService';

/// `com.webui.api.<seg>`, `<seg>` being [moduleId] with every character
/// outside `[A-Za-z0-9_]` replaced by `_`, prefixed with `m` when empty or
/// starting with a digit. Same rule as webui_app_plane's `termuxApiPackage`.
String appPlanePackage(String moduleId) {
  var seg = moduleId.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
  if (seg.isEmpty || RegExp('^[0-9]').hasMatch(seg)) seg = 'm$seg';
  return 'com.webui.api.$seg';
}

/// Runs an Android shell tool (`am`, `pm`) with the given arguments.
typedef ToolRunner = Future<ProcessResult> Function(
  String tool,
  List<String> args,
);

/// Holds the module's app plane app as a foreground service for the root
/// channel's lifetime: [hold] when the channel starts, [release] when it
/// shuts down. Both are best effort: without the app, or with an app that
/// has no such service, they log and return.
final class AppPlaneKeepAlive {
  AppPlaneKeepAlive(
    String moduleId, {
    ToolRunner? tools,
    this.timeout = const Duration(seconds: 10),
    this.log = _noLog,
  }) : package = appPlanePackage(moduleId),
       _tools = tools ?? _systemTools;

  final String package;
  final Duration timeout;
  final ToolRunner? _tools;
  final void Function(String) log;
  Future<bool>? _held;

  /// `<package>/<class>`, as `am -n` takes it.
  String get component => '$package/$appPlaneServiceClass';

  /// The tools of an Android system, or null elsewhere.
  static ToolRunner? get _systemTools {
    if (!File('/system/bin/am').existsSync()) return null;
    return (tool, args) => Process.run('/system/bin/$tool', args);
  }

  /// Starts the service when the app is installed.
  Future<void> hold() => _held ??= _hold();

  Future<bool> _hold() async {
    final found = await _run('pm', ['path', package]);
    if (found == null || !'${found.stdout}'.contains('package:')) {
      log('$package not installed; not holding it');
      return false;
    }
    await _run('am', [
      'start-foreground-service',
      '--user',
      '0',
      '-n',
      component,
    ]);
    return true;
  }

  /// Stops the service if [hold] started it, after it finished.
  Future<void> release() async {
    final held = _held;
    if (held == null || !await held) return;
    await _run('am', ['stopservice', '--user', '0', '-n', component]);
  }

  /// The result, or null after logging a failure.
  Future<ProcessResult?> _run(String tool, List<String> args) async {
    final tools = _tools;
    if (tools == null) return null;
    final what = '$tool ${args.join(' ')}';
    try {
      final result = await tools(tool, args).timeout(timeout);
      // `am` reports a missing service on stdout with status 0.
      final out = '${result.stdout}${result.stderr}'.trim();
      if (result.exitCode != 0 || out.contains('Error')) {
        log('$what: exit ${result.exitCode} $out');
        if (result.exitCode != 0) return null;
      }
      return result;
    } on Object catch (e) {
      log('$what: $e');
      return null;
    }
  }
}

void _noLog(String _) {}
