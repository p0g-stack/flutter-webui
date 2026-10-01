// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// flutter-webui: a stock Flutter web app in a KernelSU-style WebUI host.
///
/// This is the web plugin. Its registrant installs the handlers before
/// `main()` and it compiles only against the patched web engine, so the
/// build tool adds it to WebUI builds. Apps import
/// `package:flutter_webui_client` for [WebUi.host] and
/// [WebUi.connectRootChannel]; it is re-exported here.
library;

export 'package:flutter_webui_client/flutter_webui_client.dart';

export 'src/embedding.dart';
