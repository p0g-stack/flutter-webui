// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

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

  /// The root channel; only on a WebUI host.
  static Future<RootChannel> connectRootChannel() => Future.error(
    UnsupportedError('The root channel exists only in a WebUI host page.'),
  );
}
