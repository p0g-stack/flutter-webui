// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:io';

import 'package:flutter_webui_root/flutter_webui_root.dart';
import 'package:test/test.dart';

ProcessResult _ok([String out = '']) => ProcessResult(0, 0, out, '');

void main() {
  const component = 'com.webui.api.my_mod/com.termux.api.RootHelperService';

  test('package name follows webui_app_plane', () {
    expect(appPlanePackage('demo'), 'com.webui.api.demo');
    expect(appPlanePackage('my-mod.x'), 'com.webui.api.my_mod_x');
    expect(appPlanePackage('9lives'), 'com.webui.api.m9lives');
    expect(appPlanePackage(''), 'com.webui.api.m');
  });

  test('hold starts the service once, release stops it', () async {
    final calls = <String>[];
    final keepAlive = AppPlaneKeepAlive(
      'my-mod',
      tools: (tool, args) async {
        calls.add('$tool ${args.join(' ')}');
        return tool == 'pm' ? _ok('package:/data/app/x/base.apk\n') : _ok();
      },
    );
    expect(keepAlive.component, component);
    await keepAlive.hold();
    await keepAlive.hold();
    await keepAlive.release();
    expect(calls, [
      'pm path com.webui.api.my_mod',
      'am start-foreground-service --user 0 -n $component',
      'am stopservice --user 0 -n $component',
    ]);
  });

  test('without the app nothing is started or stopped', () async {
    final calls = <String>[];
    final keepAlive = AppPlaneKeepAlive(
      'my-mod',
      tools: (tool, args) async {
        calls.add(tool);
        return ProcessResult(0, 1, '', '');
      },
    );
    await keepAlive.hold();
    await keepAlive.release();
    expect(calls, ['pm']);
  });

  test('release without hold runs nothing', () async {
    var ran = false;
    final keepAlive = AppPlaneKeepAlive(
      'demo',
      tools: (_, _) async {
        ran = true;
        return _ok();
      },
    );
    await keepAlive.release();
    expect(ran, isFalse);
  });

  test('failures are logged, never thrown', () async {
    final logs = <String>[];
    final keepAlive = AppPlaneKeepAlive(
      'demo',
      timeout: const Duration(milliseconds: 50),
      log: logs.add,
      tools: (tool, args) {
        if (tool == 'pm') return Future.value(_ok('package:/x.apk'));
        if (args.first == 'start-foreground-service') {
          return Future.value(_ok('Error: Not found; no service started.'));
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
