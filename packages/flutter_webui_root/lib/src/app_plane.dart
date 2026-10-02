// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:io';

/// The foreground service in the module's app plane app that keeps the app
/// unfrozen while the root channel runs. The class name inside the
/// webui-termux-api fork; the package is [appPlanePackage].
const String appPlaneServiceClass = 'com.termux.api.WebUiForegroundService';

/// `com.webui.api.<seg>`, `<seg>` being [moduleId] with every character
/// outside `[A-Za-z0-9_]` replaced by `_`, prefixed with `m` when empty or
/// starting with a digit. Same rule as webui_app_plane's `termuxApiPackage`.
String appPlanePackage(String moduleId) {
  var seg = moduleId.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
  if (seg.isEmpty || RegExp('^[0-9]').hasMatch(seg)) seg = 'm$seg';
  return 'com.webui.api.$seg';
}

/// Runs `am` with the given arguments.
typedef AmRunner = Future<ProcessResult> Function(List<String> args);

/// Holds the module's app plane app as a foreground service for the root
/// channel's lifetime: [hold] when the channel starts, [release] when it
/// shuts down. Both are best effort: without the app, or with an app that
/// has no such service, they log and return.
final class AppPlaneKeepAlive {
  AppPlaneKeepAlive(
    String moduleId, {
    AmRunner? am,
    this.timeout = const Duration(seconds: 10),
    this.log = _noLog,
  }) : component = '${appPlanePackage(moduleId)}/$appPlaneServiceClass',
       _am = am ?? _systemAm;

  /// `<package>/<class>`, as `am -n` takes it.
  final String component;
  final Duration timeout;
  final AmRunner? _am;
  final void Function(String) log;
  Future<void>? _held;

  /// The `am` of an Android system, or null elsewhere.
  static AmRunner? get _systemAm {
    const am = '/system/bin/am';
    if (!File(am).existsSync()) return null;
    return (args) => Process.run(am, args);
  }

  Future<void> hold() => _held ??= _run('start-foreground-service');

  /// Stops the service if [hold] ran, after it finished.
  Future<void> release() async {
    final held = _held;
    if (held == null) return;
    await held;
    await _run('stopservice');
  }

  Future<void> _run(String command) async {
    final am = _am;
    if (am == null) return;
    final args = [command, '--user', '0', '-n', component];
    try {
      final result = await am(args).timeout(timeout);
      // `am` reports a missing app or service on stdout with status 0.
      final out = '${result.stdout}${result.stderr}'.trim();
      if (result.exitCode != 0 || out.contains('Error')) {
        log('am ${args.join(' ')}: exit ${result.exitCode} $out');
      }
    } on Object catch (e) {
      log('am ${args.join(' ')}: $e');
    }
  }
}

void _noLog(String _) {}
