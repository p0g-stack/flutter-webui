// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_webui_client/flutter_webui_client.dart';

/// Lifecycle states the embedding reports. Mirrors `dart:ui`'s
/// `AppLifecycleState` without importing it, so this file runs on the VM.
enum HostLifecycle { hidden }

/// Light or dark, as the host reports it.
enum HostBrightness { light, dark }

/// The patched `web_ui` hooks (`dart:ui_web` `setHost*`). The web
/// implementation forwards to them; tests record calls.
abstract interface class EngineHooks {
  void setViewPadding(Insets? padding);
  void setLifecycle(HostLifecycle? state);
  void setBrightness(HostBrightness? brightness);
  void setExitHandler(Future<void> Function()? handler);
  void setClipboard(TextClipboard? clipboard);

  /// Delivers a `popRoute` to the framework, as a platform Back does.
  void popRoute();
}

/// A text clipboard (the engine's `HostClipboard`).
abstract interface class TextClipboard {
  Future<String?> getText();
  Future<void> setText(String text);
}

/// The engine clipboard on WebUI hosts. The embedding installs the browser's
/// (async Clipboard API, which WebView refuses to read); a plugin may [use]
/// another, such as `clipboard_webui`'s, which falls back to the module's app.
/// Either order works: [use] before the embedding installs, or after.
abstract final class WebUiClipboard {
  static TextClipboard? _used;
  static WebUiEmbedding? _installed;

  /// The embedding's own clipboard (the browser's); null until a WebUI
  /// embedding installs, and in a browser tab.
  static TextClipboard? get browser => _installed?.clipboard;

  /// Makes [clipboard] the engine clipboard on WebUI hosts.
  static void use(TextClipboard clipboard) {
    _used = clipboard;
    _installed?.hooks.setClipboard(clipboard);
  }

  /// Forgets [use]'s clipboard and the installed embedding. For tests.
  static void debugReset() {
    _used = null;
    _installed = null;
  }
}

/// Connects a WebUI host to the engine, so a stock app behaves as in a
/// browser tab:
///
/// | Flutter | WebUI | WebUI X (extras, where present) |
/// |---|---|---|
/// | safe-area padding | `insets.css` variables (edge-to-edge requested) | injected variables; `WX_ON_INSETS` (v438) |
/// | `AppLifecycleState` | page visibility (`web_ui` as is) | `WX_ON_PAUSE` = hidden until `WX_ON_RESUME` (v438) |
/// | back | WebView history, kept reachable (`_installBackEntry`) | same; `WX_ON_BACK` = `history.back()` (v438 `backInterceptor: "javascript"`) |
/// | `SystemNavigator.pop` | `ksu.exit()` or `webui.exit()`, else history unwinds so the host's Back closes the page | same |
/// | brightness | the manager's `colors.css` background, else `prefers-color-scheme` | same, else `$<id>.isDarkMode()` |
/// | clipboard | [clipboard], or [WebUiClipboard.use]'s | same |
///
/// The baseline (left column) needs only what every host and version has;
/// WebUI X's own events and globals are extras, used when present.
final class WebUiEmbedding {
  WebUiEmbedding(this.host, this.bridge, this.hooks, {this.clipboard});

  final WebUiHost host;
  final HostBridge bridge;
  final EngineHooks hooks;

  /// Installed as the engine clipboard on WebUI hosts.
  final TextClipboard? clipboard;

  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Installs the handlers. In a browser tab it only listens for WebUI X
  /// events: WebUI X may define its globals after the page starts, so its
  /// first event, not the probe, is what proves it.
  void install() {
    _subscriptions.add(bridge.events.listen(_onWxEvent));
    if (!host.isWebUi) return;
    _installExit();
    WebUiClipboard._installed = this;
    final engineClipboard = WebUiClipboard._used ?? clipboard;
    if (engineClipboard != null) hooks.setClipboard(engineClipboard);
    _installInsets();
    _installBrightness();
    _installBackEntry();
  }

  /// KernelSU-family Back, and WebUI X's with `backInterceptor: "native"`, is
  /// `WebView.canGoBack()`, then `goBack()`, else the activity finishes. Chromium's history intervention leaves out of
  /// `canGoBack()` an entry the page left by `pushState` without user
  /// activation, and `web_ui` pushes its "flutter" entry over the "origin" one
  /// at startup and again after each Back. So Back from a pushed route closed
  /// the page (devicelab, KernelSU 3.3.0).
  ///
  /// On the first gesture the current entry becomes an "origin" entry for
  /// `web_ui` and the "flutter" entry is pushed again, with activation (the
  /// push also makes KernelSU re-read `canGoBack()`). Back to that origin
  /// entry then goes forward to the "flutter" entry instead of letting
  /// `web_ui` push a new one, and sends the framework its `popRoute`, so the
  /// origin entry stays reachable for every later Back. When the app pops at
  /// its root, [_exit] stands down and `web_ui` unwinds history as usual.
  void _installBackEntry() {
    var forwarding = false;
    bridge.popStateFilter = (state) {
      if (_exiting) {
        // web_ui's teardown has gone back to our origin entry; one more step
        // reaches the page's first entry, where the host's Back finishes.
        if (_unwindOneMore && _isOriginEntry(state)) {
          _unwindOneMore = false;
          bridge.historyGo(-1);
        }
        return false;
      }
      if (forwarding && _isFlutterEntry(state)) {
        forwarding = false;
        hooks.popRoute();
        return true;
      }
      if (_backArmed && !forwarding && _isOriginEntry(state)) {
        forwarding = true;
        bridge.historyGo(1);
        return true;
      }
      return false;
    };
    _subscriptions.add(
      bridge.userActivations.listen((_) {
        if (_backArmed || _exiting) return;
        final state = bridge.historyState;
        if (!_isFlutterEntry(state)) return;
        bridge
          ..historyReplaceState(const {'origin': true, 'state': null})
          ..historyPushState(state);
        _backArmed = true;
      }),
    );
  }

  // web_ui's SingleEntryBrowserHistory states.
  static bool _isOriginEntry(Object? s) => s is Map && s['origin'] == true;
  static bool _isFlutterEntry(Object? s) => s is Map && s['flutter'] == true;

  bool _exitInstalled = false;

  void _installExit() {
    if (_exitInstalled) return;
    _exitInstalled = true;
    hooks.setExitHandler(_exit);
  }

  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    if (identical(WebUiClipboard._installed, this)) {
      WebUiClipboard._installed = null;
    }
    if (host.isWebUi) bridge.popStateFilter = null;
  }

  bool _exiting = false;

  /// Whether `_installBackEntry` added its origin entry.
  bool _backArmed = false;

  /// Set on exit without an exit method once the origin entry was added.
  bool _unwindOneMore = false;

  Future<void> _exit() async {
    _exiting = true;
    // Asked now, not from the probe: the globals may have come later.
    if (bridge.ksuHas('exit')) {
      bridge.callKsu('exit');
    } else if (bridge.webuiHas('exit')) {
      bridge.callWebui('exit');
    } else {
      // web_ui unwinds history; then one more step reaches the page's first
      // entry, so the host's next Back closes the page (KernelSU Next,
      // APatch).
      _unwindOneMore = _backArmed;
    }
  }

  void _installInsets() {
    // Edge-to-edge: KernelSU names it enableEdgeToEdge, Next and APatch
    // enableInsets; WebUI X is always edge-to-edge. Requesting
    // /internal/insets.css (bootstrap) also turns it on for KernelSU.
    if (host.ksuMethods.contains('enableEdgeToEdge')) {
      bridge.callKsu('enableEdgeToEdge', [true]);
    } else if (host.ksuMethods.contains('enableInsets')) {
      bridge.callKsu('enableInsets', [true]);
    }
    _applyCssInsets();
    _subscriptions.add(
      bridge.cssInsetsChanged.listen((_) => _applyCssInsets()),
    );
  }

  void _applyCssInsets() {
    final insets = bridge.cssInsets();
    if (insets != null) hooks.setViewPadding(insets);
  }

  void _onWxEvent(HostEvent event) {
    _installExit();
    switch (event.type) {
      case 'WX_ON_PAUSE':
        hooks.setLifecycle(HostLifecycle.hidden);
      case 'WX_ON_RESUME':
        hooks.setLifecycle(null);
        _applyBrightness();
      case 'WX_ON_BACK':
        // As a browser's Back: through history, where web_ui turns it into
        // popRoute. WebUI X pages can have a single history entry (devicelab:
        // length 1 at the root route), where history.back() does nothing;
        // then hand the framework the popRoute directly.
        if (bridge.historyLength > 1) {
          bridge.historyBack();
        } else {
          hooks.popRoute();
        }
      case 'WX_ON_INSETS':
        final insets = _insetsFrom(event.data);
        if (insets != null) hooks.setViewPadding(insets);
    }
  }

  /// KernelSU's own light or dark theme (forced, or Monet) reaches its
  /// Compose UI but not the WebView, whose `prefers-color-scheme` follows the
  /// system. When it serves its theme colours in `/internal/colors.css`
  /// (KernelSU in Monet modes or the Material UI, Next on Android 12+), the
  /// page follows the luminance of their `--background` instead; with no
  /// colours the engine keeps the system's. WebUI X serves the file too;
  /// without it, its `$<id>.isDarkMode()` decides when present.
  void _installBrightness() {
    _applyBrightness();
    _subscriptions.add(
      bridge.cssColorsChanged.listen((_) => _applyBrightness()),
    );
  }

  void _applyBrightness() {
    final colors = brightnessOfCssColor(bridge.cssVariable('background'));
    if (colors == null && _readWxBrightness()) return;
    hooks.setBrightness(colors);
  }

  /// Applies WebUI X's `$<id>.isDarkMode()`; false when there is none.
  bool _readWxBrightness() {
    if (host.kind != WebUiHostKind.webuix) return false;
    final dark = bridge.callModuleGlobal(host.moduleId!, 'isDarkMode');
    if (dark is! bool) return false;
    hooks.setBrightness(dark ? HostBrightness.dark : HostBrightness.light);
    return true;
  }
}

Insets? _insetsFrom(Object? data) {
  if (data is! Map) return null;
  double? side(String key) {
    final v = data[key];
    return v is num ? v.toDouble() : null;
  }

  final top = side('top');
  final bottom = side('bottom');
  final left = side('left');
  final right = side('right');
  if (top == null && bottom == null && left == null && right == null) {
    return null;
  }
  return Insets(
    top: top ?? 0,
    bottom: bottom ?? 0,
    left: left ?? 0,
    right: right ?? 0,
  );
}

/// Dark or light for a CSS hex colour (`#rgb`, `#rrggbb`, `#rrggbbaa`): dark
/// when white text contrasts with it more than black (relative luminance
/// below about 0.18). Null for anything else.
HostBrightness? brightnessOfCssColor(String? css) {
  if (css == null) return null;
  final m = RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$')
      .firstMatch(css.trim());
  if (m == null) return null;
  var hex = m[1]!;
  if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
  double channel(int i) {
    final c = int.parse(hex.substring(i, i + 2), radix: 16) / 255;
    return c <= 0.04045
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4) as double;
  }

  final l = 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
  // Contrast with white (1.05 / (l + .05)) beats contrast with black.
  return (1.05 / (l + 0.05)) > ((l + 0.05) / 0.05)
      ? HostBrightness.dark
      : HostBrightness.light;
}
