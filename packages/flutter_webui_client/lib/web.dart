// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// The web implementation, for code that only compiles for the web (the
/// `flutter_webui` plugin): [WebUi] with its JavaScript [WebUi.bridge].
library;

export 'flutter_webui_client.dart' hide WebUi;
export 'src/web/js_bridge.dart';
export 'src/web/webui_web.dart';
