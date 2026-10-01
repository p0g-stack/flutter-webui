// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../bridge.dart';

/// [HostBridge] over the page's real globals.
final class JsHostBridge implements HostBridge {
  JSObject? get _ksu => _object(globalContext, 'ksu');
  JSObject? get _webui => _object(globalContext, 'webui');

  static JSObject? _object(JSObject on, String name) {
    final value = on.getProperty<JSAny?>(name.toJS);
    return value != null && value.typeofEquals('object')
        ? value as JSObject
        : null;
  }

  static bool _isFunction(JSObject? on, String name) =>
      on != null && on.getProperty<JSAny?>(name.toJS).typeofEquals('function');

  static Object? _call(JSObject? on, String name, List<Object?> args) {
    if (!_isFunction(on, name)) return null;
    final result = on!.callMethodVarArgs<JSAny?>(name.toJS, [
      for (final a in args) a.jsify(),
    ]);
    return result.dartify();
  }

  @override
  bool get hasKsu => _ksu != null;

  @override
  bool ksuHas(String name) => _isFunction(_ksu, name);

  @override
  bool webuiHas(String name) => _isFunction(_webui, name);

  @override
  Object? callKsu(String name, [List<Object?> args = const []]) =>
      _call(_ksu, name, args);

  @override
  Object? callWebui(String name, [List<Object?> args = const []]) =>
      _call(_webui, name, args);

  @override
  Map<String, Object?>? moduleInfo() {
    final Object? raw;
    try {
      raw = callKsu('moduleInfo');
    } on Object {
      // WebUI X throws a Java exception from moduleInfo() when its module
      // list has a null entry; the id then comes from the build's <meta>.
      return null;
    }
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Object? callModuleGlobal(String moduleId, String name) {
    final global = '\$${moduleId.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')}';
    return _call(_object(globalContext, global), name, const []);
  }

  @override
  String? meta(String name) =>
      web.document.querySelector('meta[name="$name"]')?.getAttribute('content');

  static int _execCount = 0;

  @override
  Future<ExecResult> exec(String command) {
    final ksu = _ksu;
    if (!_isFunction(ksu, 'exec')) {
      return Future.error(StateError('ksu.exec is not available'));
    }
    final name = '__flutter_webui_exec_${_execCount++}';
    final completer = Completer<ExecResult>();
    globalContext.setProperty(
      name.toJS,
      ((JSAny? code, JSAny? out, JSAny? err) {
        globalContext.delete(name.toJS);
        if (completer.isCompleted) return;
        completer.complete(
          ExecResult(
            (code.dartify() as num?)?.toInt() ?? -1,
            (out.dartify() as String?) ?? '',
            (err.dartify() as String?) ?? '',
          ),
        );
      }).toJS,
    );
    ksu!.callMethodVarArgs<JSAny?>('exec'.toJS, [
      command.toJS,
      '{}'.toJS,
      name.toJS,
    ]);
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        globalContext.delete(name.toJS);
        throw TimeoutException('ksu.exec: $command');
      },
    );
  }

  @override
  late final Stream<HostEvent> events = () {
    final controller = StreamController<HostEvent>.broadcast();
    web.window.addEventListener(
      'message',
      ((web.MessageEvent event) {
        final data = event.data.dartify();
        Object? message = data;
        if (data is String) {
          try {
            message = jsonDecode(data);
          } on FormatException {
            return;
          }
        }
        if (message is Map && message['type'] is String) {
          final type = message['type'] as String;
          if (type.startsWith('WX_')) {
            controller.add(HostEvent(type, message['data']));
          }
        }
      }).toJS,
    );
    return controller.stream;
  }();

  @override
  Insets? cssInsets() {
    final style = web.window.getComputedStyle(web.document.documentElement!);
    double? side(String name) {
      final value = style.getPropertyValue('--safe-area-inset-$name').trim();
      if (value.isEmpty) return null;
      return double.tryParse(value.replaceAll('px', '').trim());
    }

    final top = side('top');
    final right = side('right');
    final bottom = side('bottom');
    final left = side('left');
    if (top == null && right == null && bottom == null && left == null) {
      return null;
    }
    return Insets(
      top: top ?? 0,
      right: right ?? 0,
      bottom: bottom ?? 0,
      left: left ?? 0,
    );
  }

  @override
  late final Stream<void> cssInsetsChanged = () {
    final controller = StreamController<void>.broadcast();
    void changed() => controller.add(null);
    // Hosts push changes with style.setProperty on <html>.
    web.MutationObserver(
      ((
        JSArray<web.MutationRecord> _,
        web.MutationObserver _,
      ) => changed()).toJS,
    ).observe(
      web.document.documentElement!,
      web.MutationObserverInit(
        attributes: true,
        attributeFilter: ['style'.toJS].toJS,
      ),
    );
    web.window.addEventListener('resize', ((web.Event _) => changed()).toJS);
    // The bootstrap's <link id="flutter-webui-insets"> to /internal/insets.css.
    web.document
        .getElementById('flutter-webui-insets')
        ?.addEventListener('load', ((web.Event _) => changed()).toJS);
    return controller.stream;
  }();

  @override
  void historyBack() => web.window.history.back();
}
