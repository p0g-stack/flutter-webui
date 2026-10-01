// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// flutter-webui: a stock Flutter web app in a KernelSU-style WebUI host.
///
/// Apps need nothing from here to behave as in a browser tab: the web plugin
/// registrant installs the handlers. Import this for [WebUi.host] (what the
/// host offers) and [WebUi.connectRootChannel] (root processes, see
/// `docs/root-channel.md`).
library;

export 'src/bridge.dart';
export 'src/embedding.dart';
export 'src/host.dart';
export 'src/quote.dart';
export 'src/root_channel.dart';
export 'src/webui_stub.dart'
    if (dart.library.js_interop) 'src/web/webui_web.dart';
