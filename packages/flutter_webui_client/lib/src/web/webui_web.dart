// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import '../extras.dart';
import '../host.dart';
import '../root_channel.dart';
import 'js_bridge.dart';
import 'web_transport.dart';

/// The page's host.
abstract final class WebUi {
  /// The bridge to the manager's globals.
  static final JsHostBridge bridge = JsHostBridge();

  /// What the host offers, probed once.
  static final WebUiHost host = WebUiHost.detect(bridge);

  /// Home-screen shortcut to the module, where the host can pin one.
  static final ModuleShortcut shortcut = ModuleShortcut(bridge);

  /// The manager's package list, where it has one.
  static final HostPackages packages = HostPackages(bridge);

  static Future<RootChannel>? _channel;

  /// Connects to the root channel, starting it through the bridge if needed.
  /// Returns the same connection until it closes.
  static Future<RootChannel> connectRootChannel() {
    final current = _channel;
    if (current != null) {
      return current.then(
        (c) => c.isClosed ? _connect() : c,
        onError: (Object _) => _connect(),
      );
    }
    return _connect();
  }

  static Future<RootChannel> _connect() {
    final dir = host.moduleDir;
    if (!host.isWebUi || dir == null || !host.ksuMethods.contains('exec')) {
      return Future.error(
        const RootChannelException(
          'unavailable',
          'not a WebUI host with ksu.exec and a known module directory',
        ),
      );
    }
    return _channel = RootChannel.connect(
      transport: WebChannelTransport(),
      start: () => bridge.exec(channelStartCommand(dir)),
    );
  }
}
