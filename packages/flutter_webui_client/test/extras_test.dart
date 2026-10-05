// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:convert';

import 'package:flutter_webui_client/flutter_webui_client.dart';
import 'package:flutter_webui_client/testing.dart';
import 'package:test/test.dart';

void main() {
  group('ModuleShortcut', () {
    test('WebUI X v608 pins through webui.createShortcut', () {
      final bridge = FakeBridge.webuix608()
        ..webuiAnswers['createShortcut'] = true;
      final shortcut = ModuleShortcut(bridge);
      expect(shortcut.isSupported, isTrue);
      expect(shortcut.exists, isFalse);
      expect(shortcut.create(), isTrue);
      expect(bridge.calls, ['webui.createShortcut()']);
    });

    test('hasShortcut may arrive as a string', () {
      final bridge = FakeBridge.webuix608();
      bridge.webuiProperties['hasShortcut'] = 'true';
      expect(ModuleShortcut(bridge).exists, isTrue);
      bridge.webuiProperties['hasShortcut'] = 'false';
      expect(ModuleShortcut(bridge).exists, isFalse);
      bridge.webuiProperties['hasShortcut'] = null;
      expect(ModuleShortcut(bridge).exists, isNull);
    });

    test('a refused pin is false, not an error', () {
      final bridge = FakeBridge.webuix608()
        ..webuiAnswers['createShortcut'] = false;
      expect(ModuleShortcut(bridge).create(), isFalse);
    });

    test('no boolean answer is null: requested, outcome unknown', () {
      // v608: a boxed Boolean reaches the page as no boolean at all.
      for (final answer in [null, const <String, Object?>{}, 'true']) {
        final bridge = FakeBridge.webuix608()
          ..webuiAnswers['createShortcut'] = answer;
        expect(ModuleShortcut(bridge).create(), isNull);
        expect(bridge.calls, ['webui.createShortcut()']);
      }
    });

    test('elsewhere it is unsupported and calls nothing', () {
      for (final bridge in [
        FakeBridge.kernelsu(),
        FakeBridge.webuix(),
        FakeBridge.browser(),
      ]) {
        final shortcut = ModuleShortcut(bridge);
        expect(shortcut.isSupported, isFalse);
        expect(shortcut.exists, isNull);
        expect(shortcut.create, throwsUnsupportedError);
        expect(bridge.calls, isEmpty);
      }
    });
  });

  group('HostPackages', () {
    test('lists and reads packages through ksu', () {
      final bridge = FakeBridge.kernelsu();
      bridge.ksuAnswers['listPackages'] = (String type) =>
          jsonEncode(type == 'user' ? ['a.b'] : ['a.b', 'android']);
      bridge.ksuAnswers['getPackagesInfo'] = (String names) => jsonEncode([
        for (final n in jsonDecode(names) as List)
          n == 'gone'
              ? {'packageName': n, 'error': 'Package not found or inaccessible'}
              : {
                  'packageName': n,
                  'appLabel': 'App $n',
                  'versionName': '1.0',
                  'versionCode': 3,
                  'uid': 10123,
                  'isSystem': false,
                },
      ]);
      final packages = HostPackages(bridge);
      expect(packages.isSupported, isTrue);
      expect(packages.list(PackageFilter.user), ['a.b']);
      expect(packages.list(), ['a.b', 'android']);
      final info = packages.info(['a.b', 'gone']);
      expect(info.first.appLabel, 'App a.b');
      expect(info.first.versionCode, 3);
      expect(info.first.uid, 10123);
      expect(info.first.isSystem, isFalse);
      expect(info.first.found, isTrue);
      expect(info.last.error, isNotNull);
      expect(info.last.found, isFalse);
      expect(bridge.calls.first, 'ksu.listPackages(user)');
      expect(packages.iconUri('a.b').toString(), 'ksu://icon/a.b');
    });

    test('hosts without the methods are unsupported', () {
      for (final bridge in [FakeBridge.webuix(), FakeBridge.browser()]) {
        final packages = HostPackages(bridge);
        expect(packages.isSupported, isFalse);
        expect(packages.list, throwsUnsupportedError);
        expect(() => packages.info(['a']), throwsUnsupportedError);
      }
    });

    test('v608 has them', () {
      expect(HostPackages(FakeBridge.webuix608()).isSupported, isTrue);
    });
  });
}
