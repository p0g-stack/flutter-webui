// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'package:test/test.dart';
import 'package:flutter_webui_client/flutter_webui_client.dart';

import 'package:flutter_webui_client/testing.dart';

void main() {
  test('a browser tab is not a WebUI host', () {
    final host = WebUiHost.detect(FakeBridge.browser());
    expect(host.kind, WebUiHostKind.browser);
    expect(host.isWebUi, isFalse);
  });

  test('KernelSU: webui, module from moduleInfo, can exit', () {
    final host = WebUiHost.detect(FakeBridge.kernelsu());
    expect(host.kind, WebUiHostKind.webui);
    expect(host.moduleId, 'demo');
    expect(host.moduleDir, '/data/adb/modules/demo');
    expect(host.canExit, isTrue);
  });

  test('KernelSU Next: webui without exit', () {
    final host = WebUiHost.detect(FakeBridge.next());
    expect(host.kind, WebUiHostKind.webui);
    expect(host.canExit, isFalse);
    expect(host.ksuMethods, contains('enableInsets'));
  });

  test('APatch: module id from the build meta tag', () {
    final host = WebUiHost.detect(FakeBridge.apatch());
    expect(host.moduleId, 'demo');
    expect(host.moduleDir, '/data/adb/modules/demo');
  });

  test('WebUI X: detected by ksu.mmrl or window.webui; module global', () {
    final host = WebUiHost.detect(FakeBridge.webuix());
    expect(host.kind, WebUiHostKind.webuix);
    expect(host.moduleGlobal, r'$demo_mod');
    expect(host.canExit, isTrue);
    final viaWebui = WebUiHost.detect(
      FakeBridge(ksu: const {'exec'}, webui: const {'exit'}),
    );
    expect(viaWebui.kind, WebUiHostKind.webuix);
  });

  test('shell quoting', () {
    expect(
      shellQuote('/data/adb/modules/demo/flutter_webui/root'),
      '/data/adb/modules/demo/flutter_webui/root',
    );
    expect(shellQuote("it's"), r"'it'\''s'");
    expect(shellQuote(''), "''");
    expect(shellQuote(r'$(reboot)'), r"'$(reboot)'");
    expect(
      channelStartCommand('/data/adb/modules/my mod'),
      "sh '/data/adb/modules/my mod/flutter_webui/root' start",
    );
  });
}
