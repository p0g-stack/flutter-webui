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

  /// Safe-area insets from the host's CSS variables, or null if none is set.
  Insets? cssInsets();

  /// Fires when the host may have changed its CSS insets.
  Stream<void> get cssInsetsChanged;

  /// `window.history.back()`.
  void historyBack();

  /// `window.history.length`.
  int get historyLength;
}
