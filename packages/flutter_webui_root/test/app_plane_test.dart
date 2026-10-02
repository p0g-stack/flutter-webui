// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:io';

import 'package:flutter_webui_root/flutter_webui_root.dart';
import 'package:test/test.dart';

void main() {
  test('package name follows webui_app_plane', () {
    expect(appPlanePackage('demo'), 'com.webui.api.demo');
    expect(appPlanePackage('my-mod.x'), 'com.webui.api.my_mod_x');
    expect(appPlanePackage('9lives'), 'com.webui.api.m9lives');
    expect(appPlanePackage(''), 'com.webui.api.m');
  });

  test('hold starts the service once, release stops it', () async {
    final calls = <List<String>>[];
    final keepAlive = AppPlaneKeepAlive(
      'my-mod',
      am: (args) async {
        calls.add(args);
        return ProcessResult(0, 0, '', '');
      },
    );
    await keepAlive.hold();
    await keepAlive.hold();
    await keepAlive.release();
    const component = 'com.webui.api.my_mod/$appPlaneServiceClass';
    expect(calls, [
      ['start-foreground-service', '--user', '0', '-n', component],
      ['stopservice', '--user', '0', '-n', component],
    ]);
  });

  test('release without hold runs nothing', () async {
    var ran = false;
    final keepAlive = AppPlaneKeepAlive(
      'demo',
      am: (_) async {
        ran = true;
        return ProcessResult(0, 0, '', '');
      },
    );
    await keepAlive.release();
    expect(ran, isFalse);
  });

  test('failures are logged, never thrown', () async {
    final logs = <String>[];
    var n = 0;
    final keepAlive = AppPlaneKeepAlive(
      'demo',
      timeout: const Duration(milliseconds: 50),
      log: logs.add,
      am: (args) {
        n++;
        if (n == 1) {
          return Future.value(
            ProcessResult(0, 0, 'Error: Not found; no service started.', ''),
          );
        }
        return Completer<ProcessResult>().future; // hangs
      },
    );
    await keepAlive.hold();
    await keepAlive.release();
    expect(logs, hasLength(2));
    expect(logs.first, contains('Not found'));
    expect(logs.last, contains('TimeoutException'));
  });
}
