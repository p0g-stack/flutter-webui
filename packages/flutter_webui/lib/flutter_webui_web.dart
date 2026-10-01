// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// The web plugin entry point. The generated plugin registrant calls
/// [FlutterWebUi.registerWith] before `main()`, so apps stay stock.
library;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:flutter_webui_client/web.dart';

import 'src/embedding.dart';
import 'src/web/engine_hooks.dart';

/// Installs the WebUI handlers into the patched engine.
abstract final class FlutterWebUi {
  static WebUiEmbedding? _embedding;

  static void registerWith(Registrar registrar) {
    _embedding ??= WebUiEmbedding(
      WebUi.host,
      WebUi.bridge,
      UiWebHooks(),
      clipboard: BrowserClipboard(),
    )..install();
  }
}
