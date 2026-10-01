// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';

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

/// Connects a WebUI host to the engine, so a stock app behaves as in a
/// browser tab:
///
/// | Flutter | WebUI | WebUI X |
/// |---|---|---|
/// | safe-area padding | `insets.css` variables (edge-to-edge requested) | `WX_ON_INSETS`, injected variables |
/// | `AppLifecycleState` | page visibility (`web_ui` as is) | `WX_ON_PAUSE` = hidden until `WX_ON_RESUME` |
/// | back | WebView history (`web_ui` as is) | `WX_ON_BACK` = `history.back()` |
/// | `SystemNavigator.pop` | `ksu.exit()` after history unwinds | `webui.exit()` |
/// | brightness | `prefers-color-scheme` | `$<id>.isDarkMode()` on start and resume |
/// | clipboard | [clipboard] | [clipboard] |
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
    if (host.kind == WebUiHostKind.webuix) _readWxBrightness();
    if (!host.isWebUi) return;
    _installExit();
    if (clipboard != null) hooks.setClipboard(clipboard);
    _installInsets();
  }

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
  }

  Future<void> _exit() async {
    // Asked now, not from the probe: the globals may have come later.
    if (bridge.ksuHas('exit')) {
      bridge.callKsu('exit');
    } else if (bridge.webuiHas('exit')) {
      bridge.callWebui('exit');
    }
    // Otherwise history is unwound and the host's own Back closes the page.
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
        _readWxBrightness();
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

  void _readWxBrightness() {
    final global = host.moduleGlobal;
    if (global == null) return;
    final dark = bridge.callModuleGlobal(host.moduleId!, 'isDarkMode');
    if (dark is bool) {
      hooks.setBrightness(dark ? HostBrightness.dark : HostBrightness.light);
    }
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
