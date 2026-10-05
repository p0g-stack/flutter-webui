// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'bridge.dart';
import 'extras.dart';
import 'host.dart';
import 'root_channel.dart';

/// The page's host. Off the web there is none.
abstract final class WebUi {
  /// What the host offers; [WebUiHostKind.browser] off the web.
  static const WebUiHost host = WebUiHost(
    kind: WebUiHostKind.browser,
    ksuMethods: {},
    webuiMethods: {},
  );

  /// Home-screen shortcut to the module; unsupported off the web.
  static final ModuleShortcut shortcut = ModuleShortcut(_NoHost());

  /// The manager's package list; unsupported off the web.
  static final HostPackages packages = HostPackages(_NoHost());

  /// The root channel; only on a WebUI host.
  static Future<RootChannel> connectRootChannel() => Future.error(
    UnsupportedError('The root channel exists only in a WebUI host page.'),
  );
}

/// No host: every probe answers absent.
final class _NoHost implements HostBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  bool ksuHas(String name) => false;

  @override
  bool webuiHas(String name) => false;
}
