// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'bridge.dart';

/// Which family of host the page runs in. WebUI X is a child of WebUI: it has
/// the `ksu` bridge plus its own additions.
enum WebUiHostKind {
  /// A plain browser tab: no bridge.
  browser,

  /// The KernelSU WebUI bridge (`window.ksu`), from any manager.
  webui,

  /// WebUI X (WebUI X Portable, MMRL): `ksu` plus `webui`, events and
  /// `config.json`.
  webuix,
}

/// Name of the `<meta>` tag the build fills with the module id, for hosts
/// without `ksu.moduleInfo()` (APatch).
const String moduleIdMeta = 'webui-module-id';

/// What the host offers, found by probing optional bridge methods. A manager's
/// name or version never selects behaviour.
final class WebUiHost {
  const WebUiHost({
    required this.kind,
    required this.ksuMethods,
    required this.webuiMethods,
    this.moduleId,
    this.moduleDir,
  });

  /// The `ksu` methods the probe looks for.
  static const List<String> probedKsuMethods = [
    'exec',
    'spawn',
    'toast',
    'fullScreen',
    'enableEdgeToEdge',
    'enableInsets',
    'moduleInfo',
    'listPackages',
    'getPackagesInfo',
    'exit',
    'mmrl',
  ];

  /// The WebUI X `webui` methods the probe looks for.
  static const List<String> probedWebuiMethods = [
    'exit',
    'startActivity',
    'createShortcut',
  ];

  /// Probes [bridge].
  static WebUiHost detect(HostBridge bridge) {
    if (!bridge.hasKsu) {
      return const WebUiHost(
        kind: WebUiHostKind.browser,
        ksuMethods: {},
        webuiMethods: {},
      );
    }
    final ksu = {
      for (final m in probedKsuMethods)
        if (bridge.ksuHas(m)) m,
    };
    final webui = {
      for (final m in probedWebuiMethods)
        if (bridge.webuiHas(m)) m,
    };
    final kind = ksu.contains('mmrl') || webui.isNotEmpty
        ? WebUiHostKind.webuix
        : WebUiHostKind.webui;
    // The build's <meta> first: KernelSU's moduleInfo() runs `ksud module
    // list` through a root shell on the page's thread, which delays the first
    // frame. It is only the fallback for pages without the tag.
    final metaId = _nonEmpty(bridge.meta(moduleIdMeta));
    final info = metaId == null && ksu.contains('moduleInfo')
        ? bridge.moduleInfo()
        : null;
    final id = metaId ?? _nonEmpty(info?['id']);
    final dir =
        _nonEmpty(info?['moduleDir']) ??
        (id == null ? null : '/data/adb/modules/$id');
    return WebUiHost(
      kind: kind,
      ksuMethods: ksu,
      webuiMethods: webui,
      moduleId: id,
      moduleDir: dir,
    );
  }

  final WebUiHostKind kind;

  /// `ksu` methods that exist.
  final Set<String> ksuMethods;

  /// WebUI X `webui` methods that exist.
  final Set<String> webuiMethods;

  /// The module id, from the build's `<meta>` tag or else `ksu.moduleInfo()`.
  final String? moduleId;

  /// The module directory (`/data/adb/modules/<id>`).
  final String? moduleDir;

  bool get isWebUi => kind != WebUiHostKind.browser;

  /// WebUI X's module global name: `$` + id with non-word characters as `_`.
  String? get moduleGlobal => moduleId == null
      ? null
      : '\$${moduleId!.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')}';

  /// Whether the page can close itself (`ksu.exit` or `webui.exit`).
  bool get canExit =>
      ksuMethods.contains('exit') || webuiMethods.contains('exit');

  @override
  String toString() =>
      'WebUiHost(${kind.name}, ksu: ${ksuMethods.join(',')}, webui: ${webuiMethods.join(',')}, module: $moduleId)';
}

String? _nonEmpty(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
