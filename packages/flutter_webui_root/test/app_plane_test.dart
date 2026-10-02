// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:io';

import 'package:flutter_webui_root/flutter_webui_root.dart';
import 'package:test/test.dart';

ProcessResult _ok([String out = '']) => ProcessResult(0, 0, out, '');

Future<Socket> _noService(String name) =>
    Future.error(SocketException('no $name'));

void main() {
  const component = 'com.webui.api.my_mod/com.termux.api.RootHelperService';

  test('package name follows webui_app_plane', () {
    expect(appPlanePackage('demo'), 'com.webui.api.demo');
    expect(appPlanePackage('my-mod.x'), 'com.webui.api.my_mod_x');
    expect(appPlanePackage('9lives'), 'com.webui.api.m9lives');
    expect(appPlanePackage(''), 'com.webui.api.m');
  });

  test('hold starts the service once, release stops it', () async {
    final calls = <String>[];
    final keepAlive = AppPlaneKeepAlive(
      'my-mod',
      connect: _noService,
      holdRetry: Duration.zero,
      timeout: const Duration(milliseconds: 20),
      tools: (tool, args) async {
        calls.add('$tool ${args.join(' ')}');
        return tool == 'pm' ? _ok('package:/data/app/x/base.apk\n') : _ok();
      },
    );
    expect(keepAlive.component, component);
    await keepAlive.hold();
    await keepAlive.hold();
    await keepAlive.release();
    expect(calls, [
      'pm path com.webui.api.my_mod',
      'am start-foreground-service --user 0 -n $component',
      'am stopservice --user 0 -n $component',
    ]);
  });

  test('without the app nothing is started or stopped', () async {
    final calls = <String>[];
    final keepAlive = AppPlaneKeepAlive(
      'my-mod',
      tools: (tool, args) async {
        calls.add(tool);
        return ProcessResult(0, 1, '', '');
      },
    );
    await keepAlive.hold();
    await keepAlive.release();
    expect(calls, ['pm']);
  });

  test('release without hold runs nothing', () async {
    var ran = false;
    final keepAlive = AppPlaneKeepAlive(
      'demo',
      tools: (_, _) async {
        ran = true;
        return _ok();
      },
    );
    await keepAlive.release();
    expect(ran, isFalse);
  });

  test('failures are logged, never thrown', () async {
    final logs = <String>[];
    final keepAlive = AppPlaneKeepAlive(
      'demo',
      timeout: const Duration(milliseconds: 50),
      connect: _noService,
      holdRetry: const Duration(milliseconds: 10),
      log: logs.add,
      tools: (tool, args) {
        if (tool == 'pm') return Future.value(_ok('package:/x.apk'));
        if (args.first == 'start-foreground-service') {
          return Future.value(_ok('Error: Not found; no service started.'));
        }
        return Completer<ProcessResult>().future; // hangs
      },
    );
    await keepAlive.hold();
    await keepAlive.release();
    expect(logs, hasLength(3));
    expect(logs[0], contains('Not found'));
    expect(logs[1], contains('could not connect to com.webui.api.demo/hold'));
    expect(logs[2], contains('TimeoutException'));
  });

  group('hold socket', () {
    late ServerSocket service;
    late String name;
    final accepted = <Socket>[];

    setUp(() async {
      accepted.clear();
      name = 'flutter_webui_test.$pid.${DateTime.now().microsecondsSinceEpoch}';
    });

    tearDown(() async {
      await service.close();
      for (final s in accepted) {
        s.destroy();
      }
    });

    Future<void> bind() async {
      service = await ServerSocket.bind(
        InternetAddress('@$name/hold', type: InternetAddressType.unix),
        0,
      );
      service.listen(accepted.add);
    }

    AppPlaneKeepAlive keepAlive({List<String>? logs}) => AppPlaneKeepAlive(
      'x',
      tools: (tool, _) async => _ok(tool == 'pm' ? 'package:/x.apk' : ''),
      connect: (n) => Socket.connect(
        InternetAddress(
          '@${n.replaceFirst('com.webui.api.x', name)}',
          type: InternetAddressType.unix,
        ),
        0,
      ),
      holdRetry: const Duration(milliseconds: 20),
      timeout: const Duration(seconds: 2),
      log: logs?.add ?? (_) {},
    );

    test('held open until release, which closes it', () async {
      await bind();
      final k = keepAlive();
      await k.hold();
      expect(accepted, hasLength(1));
      final eof = accepted.single.toList();
      var ended = false;
      unawaited(eof.then((_) => ended = true));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ended, isFalse);
      await k.release();
      expect(await eof.timeout(const Duration(seconds: 2)), isEmpty);
    });

    test('retries while the service comes up', () async {
      final k = keepAlive();
      final held = k.hold();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await bind();
      await held;
      expect(accepted, hasLength(1));
      await k.release();
    });

    test('the service ending the connection is logged', () async {
      await bind();
      final logs = <String>[];
      final k = keepAlive(logs: logs);
      await k.hold();
      accepted.single.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(logs.single, contains('closed by the service'));
      await k.release();
    });
  });
}
