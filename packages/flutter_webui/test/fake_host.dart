// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'package:flutter_webui/flutter_webui.dart';

export 'package:flutter_webui_client/testing.dart';

/// Records what the embedding hands the engine.
class FakeHooks implements EngineHooks {
  Insets? padding;
  HostLifecycle? lifecycle;
  HostBrightness? brightness;
  Future<void> Function()? exitHandler;
  TextClipboard? clipboard;
  final List<String> log = [];

  @override
  void setViewPadding(Insets? p) {
    padding = p;
    log.add('padding $p');
  }

  @override
  void setLifecycle(HostLifecycle? s) {
    lifecycle = s;
    log.add('lifecycle $s');
  }

  @override
  void setBrightness(HostBrightness? b) {
    brightness = b;
    log.add('brightness $b');
  }

  @override
  void setExitHandler(Future<void> Function()? h) => exitHandler = h;

  @override
  void setClipboard(TextClipboard? c) => clipboard = c;
}

class FakeClipboard implements TextClipboard {
  String? text;

  @override
  Future<String?> getText() async => text;

  @override
  Future<void> setText(String t) async => text = t;
}
