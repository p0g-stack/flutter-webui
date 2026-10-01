// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:js_interop';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import '../bridge.dart';
import '../embedding.dart';

/// [EngineHooks] on the patched `web_ui` (`dart:ui_web` `setHost*`).
final class UiWebHooks implements EngineHooks {
  @override
  void setViewPadding(Insets? padding) => ui_web.setHostViewPadding(
    padding == null
        ? null
        : ui_web.HostInsets(
            left: padding.left,
            top: padding.top,
            right: padding.right,
            bottom: padding.bottom,
          ),
  );

  @override
  void setLifecycle(HostLifecycle? state) =>
      ui_web.setHostAppLifecycleState(switch (state) {
        HostLifecycle.hidden => ui.AppLifecycleState.hidden,
        null => null,
      });

  @override
  void setBrightness(HostBrightness? brightness) =>
      ui_web.setHostPlatformBrightness(switch (brightness) {
        HostBrightness.light => ui.Brightness.light,
        HostBrightness.dark => ui.Brightness.dark,
        null => null,
      });

  @override
  void setExitHandler(Future<void> Function()? handler) =>
      ui_web.setHostExitHandler(handler);

  @override
  void setClipboard(TextClipboard? clipboard) => ui_web.setHostClipboard(
    clipboard == null ? null : _EngineClipboard(clipboard),
  );
}

final class _EngineClipboard implements ui_web.HostClipboard {
  _EngineClipboard(this._clipboard);

  final TextClipboard _clipboard;

  @override
  Future<String?> getText() => _clipboard.getText();

  @override
  Future<void> setText(String text) => _clipboard.setText(text);
}

/// The browser clipboard, with the `execCommand('copy')` fallback for
/// WebViews that refuse the async API. Reading needs the async API; where the
/// WebView refuses it, a plugin can install a root-backed clipboard instead.
final class BrowserClipboard implements TextClipboard {
  @override
  Future<String?> getText() async {
    try {
      return (await web.window.navigator.clipboard.readText().toDart).toDart;
    } on Object {
      throw StateError('Clipboard read is not available in this WebView.');
    }
  }

  @override
  Future<void> setText(String text) async {
    try {
      await web.window.navigator.clipboard.writeText(text).toDart;
      return;
    } on Object {
      // Fall through to execCommand.
    }
    final area =
        web.document.createElement('textarea') as web.HTMLTextAreaElement
          ..value = text
          ..style.position = 'fixed'
          ..style.opacity = '0';
    web.document.body!.append(area);
    area.select();
    final copied = web.document.execCommand('copy');
    area.remove();
    if (!copied) throw StateError('Clipboard write was refused.');
  }
}
