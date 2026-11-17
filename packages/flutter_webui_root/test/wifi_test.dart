// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:io';

import 'package:flutter_webui_root/flutter_webui_root.dart';
import 'package:test/test.dart';

void main() {
  test('root toggles either state directly, without su', () async {
    for (final enabled in [true, false]) {
      final calls = <List<String>>[];
      final error = await setWifiEnabled(
        enabled,
        tools: (tool, args) async {
          calls.add([tool, ...args]);
          return ProcessResult(1, 0, tool == 'id' ? '0\n' : '', '');
        },
      );
      expect(error, isNull);
      expect(calls, [
        ['id', '-u'],
        ['cmd', 'wifi', 'set-wifi-enabled', enabled ? 'enabled' : 'disabled'],
      ]);
    }
  });

  test('non-root and unknown identities never mutate Wi-Fi', () async {
    for (final uid in ['2000', '10001', '']) {
      final calls = <String>[];
      final error = await setWifiEnabled(
        true,
        tools: (tool, args) async {
          calls.add(tool);
          return ProcessResult(1, 0, uid, '');
        },
      );
      expect(error, {'error': 'WifiEnable needs root', 'code': 'needs_root'});
      expect(calls, ['id']);
    }
  });

  test('missing identity tool reports needs root', () async {
    expect(
      await setWifiEnabled(
        true,
        tools: (tool, args) async => throw ProcessException(tool, args),
      ),
      {'error': 'WifiEnable needs root', 'code': 'needs_root'},
    );
  });

  test('command failure is not reported as success', () async {
    final error = await setWifiEnabled(
      false,
      tools: (tool, args) async => tool == 'id'
          ? ProcessResult(1, 0, '0', '')
          : ProcessResult(2, 1, '', 'denied'),
    );
    expect(error?['code'], 'wifi_enable_failed');
    expect(error?['error'], contains('denied'));
  });
}
