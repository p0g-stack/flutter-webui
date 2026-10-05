// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// The page side of flutter-webui that apps import: [WebUi.host] (what the
/// host offers) and [WebUi.connectRootChannel] (root processes, see
/// `docs/root-channel.md`).
///
/// Plain Dart against a stock SDK: an app can depend on this whether or not
/// it is built with the patched web engine. The engine handlers live in the
/// `flutter_webui` web plugin.
library;

export 'src/bridge.dart';
export 'src/extras.dart';
export 'src/host.dart';
export 'src/quote.dart';
export 'src/root_channel.dart';
export 'src/webui_stub.dart'
    if (dart.library.js_interop) 'src/web/webui_web.dart';
