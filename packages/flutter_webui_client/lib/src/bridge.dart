// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';

/// Result of one `ksu.exec`.
final class ExecResult {
  const ExecResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  @override
  String toString() => 'ExecResult($exitCode, $stdout, $stderr)';
}

/// The host refused `ksu.exec`: the command did not run and no result will
/// come. WebUI X gates exec behind `kernelsu.permission.SHELL` in the
/// module's `webroot/config.json` `permissions`: without it the call returns
/// at once, the user is asked (Allow reloads the page), and a Reject stands
/// until the manager restarts.
final class ShellRefusedException implements Exception {
  const ShellRefusedException(this.command);

  final String command;

  String get message =>
      'the host refused shell access (WebUI X: add '
      '"kernelsu.permission.SHELL" to "permissions" in webroot/config.json, '
      'or allow it when asked)';

  @override
  String toString() => 'ShellRefusedException: $message';
}

/// An event a WebUI X host posts to the page (`WX_ON_*`).
final class HostEvent {
  const HostEvent(this.type, [this.data]);

  final String type;
  final Object? data;

  @override
  String toString() => 'HostEvent($type, $data)';
}

/// Safe-area insets in logical pixels.
final class Insets {
  const Insets({this.left = 0, this.top = 0, this.right = 0, this.bottom = 0});

  final double left;
  final double top;
  final double right;
  final double bottom;

  @override
  bool operator ==(Object other) =>
      other is Insets &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'Insets($left, $top, $right, $bottom)';
}

/// The page's view of the manager: the `ksu` / `webui` globals, WebUI X
/// events, and the few DOM facts the embedding reads. The web implementation
/// is `JsHostBridge`; tests use fakes.
abstract interface class HostBridge {
  /// Whether `window.ksu` exists.
  bool get hasKsu;

  /// Whether `window.ksu[name]` is a function.
  bool ksuHas(String name);

  /// Whether `window.webui[name]` is a function (WebUI X).
  bool webuiHas(String name);

  /// Calls `ksu[name](...args)` and returns its result.
  Object? callKsu(String name, [List<Object?> args = const []]);

  /// Calls `webui[name](...args)` and returns its result.
  Object? callWebui(String name, [List<Object?> args = const []]);

  /// `webui[name]` when it is a value, not a function (WebUI X reads its
  /// properties, such as `hasShortcut`, when the page loads); null if absent.
  Object? webuiProperty(String name);

  /// `ksu.moduleInfo()`, parsed, or null if absent or unparseable.
  Map<String, Object?>? moduleInfo();

  /// Calls the WebUI X module global `$<sanitizedId>[name]()`, or returns null
  /// if it does not exist.
  Object? callModuleGlobal(String moduleId, String name);

  /// Content of `<meta name="name">` in the page.
  String? meta(String name);

  /// `ksu.exec(command, '{}', callback)`, with the callback answered.
  Future<ExecResult> exec(String command);

  /// WebUI X `WX_*` events.
  Stream<HostEvent> get events;

  /// WebUI X `document.addMXEventListener` events named [names] (v608 and
  /// later define it after `DOMContentLoaded`), as [HostEvent]s typed by
  /// name with the event's payload fields as a map. Empty where the host has
  /// no such listener. Each call registers its own listeners; WebUI X keeps
  /// one per event name on `document`, so call it once per name.
  Stream<HostEvent> mxEvents(List<String> names);

  /// Safe-area insets from the host's CSS variables, or null if none is set.
  Insets? cssInsets();

  /// Fires when the host may have changed its CSS insets.
  Stream<void> get cssInsetsChanged;

  /// A CSS custom property on `<html>` (`--<name>`), trimmed, or null if
  /// unset.
  String? cssVariable(String name);

  /// Fires when the host's `/internal/colors.css` may have changed: its
  /// first load, and a reload on a system theme change or when the page is
  /// shown again.
  Stream<void> get cssColorsChanged;

  /// `window.history.back()`.
  void historyBack();

  /// `window.history.length`.
  int get historyLength;

  /// `window.history.state`, as Dart values.
  Object? get historyState;

  /// `history.replaceState(state, '')`: the current entry, same URL.
  void historyReplaceState(Object? state);

  /// `history.pushState(state, '')`: a new entry, same URL.
  void historyPushState(Object? state);

  /// `history.go(delta)`.
  void historyGo(int delta);

  /// Sees each `popstate` before the page's own listeners; returning true
  /// stops it there.
  set popStateFilter(bool Function(Object? state)? filter);

  /// Input that gave the page user activation (a tap or a key), as Chromium
  /// counts it (`navigator.userActivation.isActive`).
  Stream<void> get userActivations;
}
