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

  /// WebUI X v608: no `WX_*` events; `document.addMXEventListener` back
  /// events, shortcuts and the package list.
  factory FakeBridge.webuix608() =>
      FakeBridge(
          ksu: const {
            'exec',
            'spawn',
            'toast',
            'fullScreen',
            'moduleInfo',
            'listPackages',
            'getPackagesInfo',
            'mmrl',
          },
          webui: const {'exit', 'startActivity', 'createShortcut'},
          info: const {
            'id': 'demo-mod',
            'moduleDir': '/data/adb/modules/demo-mod',
          },
          insets: const Insets(top: 30, bottom: 20),
        )
        ..mxListener = true
        ..webuiProperties['hasShortcut'] = false;

  /// A browser tab.
  factory FakeBridge.browser() => FakeBridge();

  final Set<String> ksu;
  final Set<String> webui;
  final Map<String, Object?>? info;
  String? metaId;
  bool? darkMode;
  Insets? insets;

  final List<String> calls = [];
  final List<String> execs = [];
  int backs = 0;

  /// `ksu.moduleInfo()` calls (a root shell round trip on KernelSU).
  int moduleInfoCalls = 0;
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
    final answer = ksuAnswers[name];
    return answer is Function ? Function.apply(answer, args) : answer;
  }

  @override
  Object? callWebui(String name, [List<Object?> args = const []]) {
    calls.add('webui.$name(${args.join(',')})');
    final answer = webuiAnswers[name];
    return answer is Function ? Function.apply(answer, args) : answer;
  }

  /// What `webui[name]()` returns, or a function computing it from the
  /// arguments; null when unset.
  final Map<String, Object?> webuiAnswers = {};

  /// `webui` properties (values, not functions).
  final Map<String, Object?> webuiProperties = {};

  @override
  Object? webuiProperty(String name) => webuiProperties[name];

  /// What `ksu[name]()` returns, or a function computing it from the
  /// arguments; null when unset.
  final Map<String, Object?> ksuAnswers = {};

  @override
  Map<String, Object?>? moduleInfo() {
    moduleInfoCalls++;
    return info;
  }

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

  /// Whether `document.addMXEventListener` exists (WebUI X v608).
  bool mxListener = false;

  /// The names [mxEvents] registered, in order.
  final List<String> mxRegistered = [];

  final StreamController<HostEvent> mxController = StreamController.broadcast(
    sync: true,
  );

  @override
  Stream<HostEvent> mxEvents(List<String> names) {
    if (!mxListener) return const Stream.empty();
    mxRegistered.addAll(names);
    return mxController.stream.where((e) => names.contains(e.type));
  }

  /// Delivers the MX event [name] with [payload] to listeners that
  /// registered it.
  void emitMx(String name, [Map<String, Object?> payload = const {}]) {
    if (mxRegistered.contains(name)) mxController.add(HostEvent(name, payload));
  }

  @override
  Insets? cssInsets() => insets;

  @override
  Stream<void> get cssInsetsChanged => insetsController.stream;

  /// CSS custom properties on `<html>`, by name without `--`.
  final Map<String, String> cssVariables = {};

  @override
  String? cssVariable(String name) => cssVariables[name];

  final StreamController<void> colorsController = StreamController.broadcast(
    sync: true,
  );

  @override
  Stream<void> get cssColorsChanged => colorsController.stream;

  @override
  void historyBack() => backs++;

  /// `history.length`; WebUI X v438 pages report 1 at the root route.
  @override
  int historyLength = 2;

  /// `history.state`; starts as `web_ui`'s single-entry "flutter" entry.
  @override
  Object? historyState = const {'flutter': true};

  /// replaceState / pushState calls, in order, as `(method, state)`.
  final List<(String, Object?)> historyWrites = [];

  @override
  void historyReplaceState(Object? state) {
    historyWrites.add(('replace', state));
    historyState = state;
  }

  @override
  void historyPushState(Object? state) {
    historyWrites.add(('push', state));
    historyLength++;
    historyState = state;
  }

  /// `history.go` deltas, in order.
  final List<int> historyGos = [];

  @override
  void historyGo(int delta) => historyGos.add(delta);

  @override
  bool Function(Object? state)? popStateFilter;

  /// Delivers a `popstate` with [state] (after setting [historyState]);
  /// returns whether [popStateFilter] stopped it.
  bool popState(Object? state) {
    historyState = state;
    return popStateFilter?.call(state) ?? false;
  }

  final StreamController<void> activationController =
      StreamController.broadcast(sync: true);

  @override
  Stream<void> get userActivations => activationController.stream;
}
