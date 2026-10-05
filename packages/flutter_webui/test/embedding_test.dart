// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webui/flutter_webui.dart';

import 'fake_host.dart';

(FakeBridge, FakeHooks, WebUiEmbedding) install(FakeBridge bridge) {
  final hooks = FakeHooks();
  final embedding = WebUiEmbedding(
    WebUiHost.detect(bridge),
    bridge,
    hooks,
    clipboard: FakeClipboard(),
  )..install();
  return (bridge, hooks, embedding);
}

void main() {
  tearDown(WebUiClipboard.debugReset);

  test('a browser tab gets nothing', () {
    final (bridge, hooks, _) = install(FakeBridge.browser());
    expect(hooks.log, isEmpty);
    expect(hooks.exitHandler, isNull);
    expect(hooks.clipboard, isNull);
    expect(bridge.calls, isEmpty);
  });

  test(
    'KernelSU: edge-to-edge, CSS insets and their changes, ksu.exit',
    () async {
      final (bridge, hooks, _) = install(FakeBridge.kernelsu());
      expect(bridge.calls, ['ksu.enableEdgeToEdge(true)']);
      expect(hooks.padding, const Insets(top: 24, bottom: 48));
      bridge.insets = const Insets(top: 24, bottom: 0, left: 10);
      bridge.insetsController.add(null);
      expect(hooks.padding, const Insets(top: 24, left: 10));
      await hooks.exitHandler!();
      expect(bridge.calls.last, 'ksu.exit()');
      expect(hooks.clipboard, isNotNull);
      expect(hooks.lifecycle, isNull);
    },
  );

  test('a plugin clipboard replaces the browser one, in either order', () {
    final mine = FakeClipboard();
    final (_, hooks, embedding) = install(FakeBridge.kernelsu());
    addTearDown(embedding.dispose);
    final browser = hooks.clipboard;
    expect(WebUiClipboard.browser, same(browser));
    WebUiClipboard.use(mine);
    expect(hooks.clipboard, same(mine));
    // A later embedding (hot restart) keeps the plugin's.
    embedding.dispose();
    expect(WebUiClipboard.browser, isNull);
    final (_, hooks2, embedding2) = install(FakeBridge.kernelsu());
    addTearDown(embedding2.dispose);
    expect(hooks2.clipboard, same(mine));
  });

  test('a plugin clipboard stays out of a browser tab', () {
    WebUiClipboard.use(FakeClipboard());
    final (_, hooks, embedding) = install(FakeBridge.browser());
    addTearDown(embedding.dispose);
    expect(hooks.clipboard, isNull);
    WebUiClipboard.use(FakeClipboard());
    expect(hooks.clipboard, isNull);
  });

  test('Next: enableInsets; exit leaves Back to the host', () async {
    final (bridge, hooks, _) = install(FakeBridge.next());
    expect(bridge.calls, ['ksu.enableInsets(true)']);
    await hooks.exitHandler!();
    expect(bridge.calls, ['ksu.enableInsets(true)']);
  });

  test('no CSS insets leaves the engine padding alone', () {
    final (_, hooks, _) = install(FakeBridge.apatch());
    expect(hooks.padding, isNull);
  });

  test('WebUI X: pause/resume map to hidden and back, as a hidden tab', () {
    final (bridge, hooks, _) = install(FakeBridge.webuix());
    expect(hooks.brightness, HostBrightness.dark);
    bridge.eventController.add(const HostEvent('WX_ON_PAUSE'));
    expect(hooks.lifecycle, HostLifecycle.hidden);
    bridge.darkMode = false;
    bridge.eventController.add(const HostEvent('WX_ON_RESUME'));
    expect(hooks.log.sublist(hooks.log.length - 2), [
      'lifecycle null',
      'brightness HostBrightness.light',
    ]);
  });

  test('WebUI X: Back walks history; insets events; webui.exit', () async {
    final (bridge, hooks, _) = install(FakeBridge.webuix());
    expect(hooks.padding, const Insets(top: 30, bottom: 20));
    bridge.eventController.add(const HostEvent('WX_ON_BACK'));
    expect(bridge.backs, 1);
    bridge.eventController.add(
      const HostEvent('WX_ON_INSETS', {
        'top': 12,
        'bottom': 34,
        'left': 0,
        'right': 0,
      }),
    );
    expect(hooks.padding, const Insets(top: 12, bottom: 34));
    bridge.eventController.add(const HostEvent('WX_ON_INSETS', 'garbage'));
    expect(hooks.padding, const Insets(top: 12, bottom: 34));
    await hooks.exitHandler!();
    expect(bridge.calls.last, 'webui.exit()');
  });

  test(
    'WebUI X detected late: its first event installs Back and exit',
    () async {
      // The probe ran before WebUI X defined its globals.
      final early = FakeBridge.browser();
      final hooks = FakeHooks();
      final bridge = FakeBridge.webuix();
      WebUiEmbedding(WebUiHost.detect(early), bridge, hooks).install();
      expect(hooks.exitHandler, isNull);
      bridge.eventController.add(const HostEvent('WX_ON_BACK'));
      expect(bridge.backs, 1);
      await hooks.exitHandler!();
      expect(bridge.calls.last, 'webui.exit()');
    },
  );

  test('WebUI X: Back with a single history entry goes to popRoute', () {
    final (bridge, hooks, _) = install(FakeBridge.webuix()..historyLength = 1);
    bridge.eventController.add(const HostEvent('WX_ON_BACK'));
    expect(bridge.backs, 0);
    expect(hooks.popRoutes, 1);
  });

  test('KernelSU: Back stays reachable after the first gesture', () async {
    final (bridge, hooks, _) = install(FakeBridge.kernelsu());
    const origin = {'origin': true, 'state': null};
    const flutter = {'flutter': true};
    // Before any gesture web_ui's entries are left alone.
    expect(bridge.popState(origin), isFalse);
    bridge.historyState = flutter;
    bridge.activationController.add(null);
    expect(bridge.historyWrites, [('replace', origin), ('push', flutter)]);
    bridge.activationController.add(null);
    expect(bridge.historyWrites, hasLength(2), reason: 'armed once');
    // Back, twice: forward again to the flutter entry, then popRoute.
    for (var i = 1; i <= 2; i++) {
      expect(bridge.popState(origin), isTrue);
      expect(bridge.historyGos, List.filled(i, 1));
      expect(hooks.popRoutes, i - 1);
      expect(bridge.popState(flutter), isTrue);
      expect(hooks.popRoutes, i);
    }
    expect(bridge.historyWrites, hasLength(2), reason: 'nothing pushed');
    // Popped at the root: web_ui unwinds history itself.
    await hooks.exitHandler!();
    expect(bridge.popState(origin), isFalse);
    expect(bridge.historyGos, hasLength(2));
  });

  test(
    'Next: popped at the root, history unwinds to the first entry',
    () async {
      final (bridge, hooks, _) = install(FakeBridge.next());
      const origin = {'origin': true, 'state': null};
      bridge.activationController.add(null);
      await hooks.exitHandler!();
      // web_ui's teardown lands on our origin entry: one more step back.
      expect(bridge.popState(origin), isFalse);
      expect(bridge.historyGos, [-1]);
      expect(bridge.popState(origin), isFalse);
      expect(bridge.historyGos, [-1], reason: 'only once');
    },
  );

  test(
    'Next: without a gesture, teardown alone reaches the first entry',
    () async {
      final (bridge, hooks, _) = install(FakeBridge.next());
      await hooks.exitHandler!();
      expect(bridge.popState(const {'origin': true, 'state': null}), isFalse);
      expect(bridge.historyGos, isEmpty);
    },
  );

  test('KernelSU: an app on its own history entries is left alone', () {
    final (bridge, _, _) = install(FakeBridge.kernelsu());
    bridge.historyState = {'serialCount': 1, 'state': null};
    bridge.activationController.add(null);
    expect(bridge.historyWrites, isEmpty);
    expect(bridge.popState({'serialCount': 0, 'state': null}), isFalse);
  });

  test('a browser tab leaves history alone', () {
    final (bridge, _, _) = install(FakeBridge.browser());
    bridge.activationController.add(null);
    expect(bridge.historyWrites, isEmpty);
    expect(bridge.popStateFilter, isNull);
  });

  test('WebUI X keeps its Back entry as KernelSU does', () {
    // backInterceptor "native" (v608) is WebView history, as on KernelSU.
    final (bridge, _, _) = install(FakeBridge.webuix());
    expect(bridge.popStateFilter, isNotNull);
    bridge.activationController.add(null);
    expect(bridge.historyWrites, isNotEmpty);
  });

  test('KernelSU: brightness follows the theme colours when served', () {
    final bridge = FakeBridge.kernelsu()
      ..cssVariables['background'] = '#1a1c1e';
    final (_, hooks, _) = install(bridge);
    expect(hooks.brightness, HostBrightness.dark);
    // Forced light, read again on a reload of colors.css.
    bridge.cssVariables['background'] = '#FDFCFF';
    bridge.colorsController.add(null);
    expect(hooks.brightness, HostBrightness.light);
    // No colours (not Monet): the system's.
    bridge.cssVariables.clear();
    bridge.colorsController.add(null);
    expect(hooks.brightness, isNull);
  });

  test('WebUI X follows its colours, else isDarkMode()', () {
    final bridge = FakeBridge.webuix()..cssVariables['background'] = '#ffffff';
    final (_, hooks, _) = install(bridge);
    expect(hooks.brightness, HostBrightness.light);
    bridge.cssVariables.clear();
    bridge.colorsController.add(null);
    expect(hooks.brightness, HostBrightness.dark);
  });

  test('brightnessOfCssColor', () {
    expect(brightnessOfCssColor('#000'), HostBrightness.dark);
    expect(brightnessOfCssColor('#fff'), HostBrightness.light);
    expect(brightnessOfCssColor(' #111318 '), HostBrightness.dark);
    expect(brightnessOfCssColor('#f8f9ffff'), HostBrightness.light);
    expect(brightnessOfCssColor('#757575'), HostBrightness.dark);
    expect(brightnessOfCssColor('#767676'), HostBrightness.light);
    for (final bad in [null, '', 'black', 'rgb(0,0,0)', '#12345']) {
      expect(brightnessOfCssColor(bad), isNull, reason: '$bad');
    }
  });

  test('dispose stops listening', () {
    final (bridge, hooks, embedding) = install(FakeBridge.webuix());
    embedding.dispose();
    bridge.eventController.add(const HostEvent('WX_ON_PAUSE'));
    expect(hooks.lifecycle, isNull);
  });
}
