// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// Test doubles for code that uses this package.
library;

import 'dart:async';

import 'flutter_webui_client.dart';

/// A scriptable [HostBridge] for tests. Profiles mirror the hosts in
/// docs/hosts.md.
class FakeBridge implements HostBridge {
  FakeBridge({
    this.ksu = const {},
    this.webui = const {},
    this.info,
    this.metaId,
    this.darkMode,
    this.insets,
  });

  /// KernelSU: full bridge.
  factory FakeBridge.kernelsu() => FakeBridge(
    ksu: const {
      'exec',
      'spawn',
      'toast',
      'fullScreen',
      'enableEdgeToEdge',
      'moduleInfo',
      'listPackages',
      'getPackagesInfo',
      'exit',
    },
    info: const {'id': 'demo', 'moduleDir': '/data/adb/modules/demo'},
    insets: const Insets(top: 24, bottom: 48),
  );

  /// KernelSU Next: enableInsets, no exit.
  factory FakeBridge.next() => FakeBridge(
    ksu: const {
      'exec',
      'spawn',
      'toast',
      'fullScreen',
      'enableInsets',
      'moduleInfo',
      'listPackages',
      'getPackagesInfo',
    },
    info: const {'id': 'demo', 'moduleDir': '/data/adb/modules/demo'},
    insets: const Insets(top: 24, bottom: 48),
  );

  /// APatch: no moduleInfo, no exit.
  factory FakeBridge.apatch() => FakeBridge(
    ksu: const {
      'exec',
      'spawn',
      'toast',
      'fullScreen',
      'enableInsets',
      'listPackages',
      'getPackagesInfo',
    },
    metaId: 'demo',
  );

  /// WebUI X Portable.
  factory FakeBridge.webuix() => FakeBridge(
    ksu: const {'exec', 'spawn', 'toast', 'fullScreen', 'moduleInfo', 'mmrl'},
    webui: const {'exit', 'startActivity'},
    info: const {'id': 'demo-mod', 'moduleDir': '/data/adb/modules/demo-mod'},
    darkMode: true,
    insets: const Insets(top: 30, bottom: 20),
  );

  /// A browser tab.
  factory FakeBridge.browser() => FakeBridge();

  final Set<String> ksu;
  final Set<String> webui;
  final Map<String, Object?>? info;
  final String? metaId;
  bool? darkMode;
  Insets? insets;

  final List<String> calls = [];
  final List<String> execs = [];
  int backs = 0;
  final StreamController<HostEvent> eventController =
      StreamController.broadcast(sync: true);
  final StreamController<void> insetsController = StreamController.broadcast(
    sync: true,
  );
  Future<ExecResult> Function(String command)? onExec;

  @override
  bool get hasKsu => ksu.isNotEmpty;

  @override
  bool ksuHas(String name) => ksu.contains(name);

  @override
  bool webuiHas(String name) => webui.contains(name);

  @override
  Object? callKsu(String name, [List<Object?> args = const []]) {
    calls.add('ksu.$name(${args.join(',')})');
    return null;
  }

  @override
  Object? callWebui(String name, [List<Object?> args = const []]) {
    calls.add('webui.$name(${args.join(',')})');
    return null;
  }

  @override
  Map<String, Object?>? moduleInfo() => info;

  @override
  Object? callModuleGlobal(String moduleId, String name) {
    calls.add('\$$moduleId.$name()');
    return name == 'isDarkMode' ? darkMode : null;
  }

  @override
  String? meta(String name) => name == moduleIdMeta ? metaId : null;

  @override
  Future<ExecResult> exec(String command) {
    execs.add(command);
    return onExec?.call(command) ?? Future.value(const ExecResult(0, '', ''));
  }

  @override
  Stream<HostEvent> get events => eventController.stream;

  @override
  Insets? cssInsets() => insets;

  @override
  Stream<void> get cssInsetsChanged => insetsController.stream;

  @override
  void historyBack() => backs++;
}
