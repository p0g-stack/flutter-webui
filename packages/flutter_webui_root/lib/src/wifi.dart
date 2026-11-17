// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:io';

import 'app_plane.dart';

/// Sets Wi-Fi through Android's root shell command without requesting `su`.
///
/// Used by the root-side Termux:API client for `WifiEnable`, since ordinary
/// apps cannot toggle Wi-Fi at current target SDKs. Returns null on success,
/// otherwise a Termux:API JSON error object. [tools] replaces system commands
/// in tests; the production path checks its effective uid before mutation.
Future<Map<String, String>?> setWifiEnabled(
  bool enabled, {
  ToolRunner? tools,
}) async {
  final run = tools ?? _systemTool;
  final ProcessResult identity;
  try {
    identity = await run('id', ['-u']);
  } on ProcessException {
    return _needsRoot;
  }
  if (identity.exitCode != 0 || '${identity.stdout}'.trim() != '0') {
    return _needsRoot;
  }
  try {
    final result = await run('cmd', [
      'wifi',
      'set-wifi-enabled',
      enabled ? 'enabled' : 'disabled',
    ]);
    if (result.exitCode == 0) return null;
    return {
      'error': 'WifiEnable failed: ${result.stderr}${result.stdout}'.trim(),
      'code': 'wifi_enable_failed',
    };
  } on ProcessException catch (error) {
    return {'error': 'WifiEnable failed: $error', 'code': 'wifi_enable_failed'};
  }
}

const _needsRoot = {'error': 'WifiEnable needs root', 'code': 'needs_root'};

Future<ProcessResult> _systemTool(String tool, List<String> args) =>
    Process.run('/system/bin/$tool', args);
