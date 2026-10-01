// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_webui_client/flutter_webui_client.dart';
import 'package:flutter_webui_client/src/io_transport.dart';
import 'package:flutter_webui_root/flutter_webui_root.dart';

/// tmp.config in memory, in place of `ksud module config`.
class _Config implements ModuleConfig {
  final Map<String, String> temp = {};

  @override
  Future<String?> get(String key) async => temp[key];

  @override
  Future<void> setTemp(String key, String value) async => temp[key] = value;

  @override
  Future<void> deleteTemp(String key) async => temp.remove(key);
}

/// The page client against the real channel. `start` runs the launcher
/// in-process where the bridge would run `root start`, and the launcher
/// starts the channel in-process where it would spawn `root serve`.
void main() {
  late Directory moduleDir;
  late _Config config;
  final transport = IoChannelTransport(origin: managerOrigin);
  final servers = <RootChannelServer>[];
  var spawns = 0;

  Future<ExecResult> start() async {
    final runDir = Directory('${moduleDir.path}/flutter_webui/run');
    try {
      final info = await ChannelLauncher(
        runDir: runDir,
        tempDir: Directory('${moduleDir.path}/data/tmp'),
        config: config,
        spawn: () async {
          spawns++;
          final server = await RootChannelServer.start(
            moduleDir: moduleDir,
            runDir: runDir,
            store: SessionStore(config),
          );
          servers.add(server);
          return Stream.value(
            utf8.encode('${jsonEncode(server.info.toJson())}\n'),
          );
        },
      ).run();
      return ExecResult(0, '${jsonEncode(info.toJson())}\n', '');
    } on LauncherException catch (e) {
      return ExecResult(1, '', '$e');
    }
  }

  setUp(() async {
    moduleDir = await Directory.systemTemp.createTemp('module');
    config = _Config();
    spawns = 0;
  });

  tearDown(() async {
    for (final s in servers) {
      await s.shutdown();
    }
    servers.clear();
    await moduleDir.delete(recursive: true);
  });

  test('starts the channel when there is none, then reuses it', () async {
    final first = await RootChannel.connect(transport: transport, start: start);
    expect(spawns, 1);
    expect(first.moduleDir, moduleDir.absolute.path);
    await first.close();
    final second = await RootChannel.connect(
      transport: transport,
      start: start,
    );
    expect(spawns, 1);
    expect(second.session.pid, first.session.pid);
    expect(second.session.token, first.session.token);
    await second.close();
  });

  test('tries root start once more if its channel went away', () async {
    var calls = 0;
    final channel = await RootChannel.connect(
      transport: transport,
      start: () async {
        if (calls++ > 0) return start();
        // A session whose channel exited in the meantime.
        return ExecResult(
          0,
          '${jsonEncode({'protocol': 1, 'version': channelVersion, 'port': 1, 'token': 'x', 'pid': 1, 'boot': 'b', 'started': '2026-01-01T00:00:00Z'})}\n',
          '',
        );
      },
    );
    expect(calls, 2);
    await channel.close();
  });

  test('fails clearly when root start fails', () async {
    await expectLater(
      RootChannel.connect(
        transport: transport,
        start: () async => const ExecResult(1, '', 'flutter_webui: no ksud'),
      ),
      throwsA(
        isA<RootChannelException>()
            .having((e) => e.code, 'code', 'unavailable')
            .having((e) => e.message, 'message', contains('no ksud')),
      ),
    );
  });

  test('parseSession takes the last line', () {
    final info = RootChannel.parseSession(
      'noise\n{"protocol":1,"version":"0.1.0","port":5,"token":"t",'
      '"pid":2,"boot":"b","started":"2026-01-01T00:00:00Z"}\n\n',
    );
    expect(info?.port, 5);
    expect(RootChannel.parseSession(''), isNull);
    expect(RootChannel.parseSession('{"port":5}'), isNull);
  });

  test('attached process: stdin, stdout lines, stderr, exit code', () async {
    final channel = await RootChannel.connect(
      transport: transport,
      start: start,
    );
    final p = await channel.start([
      '/bin/sh',
      '-c',
      r'read x; echo "hi $x"; echo e >&2; exit 2',
    ]);
    expect(p.pid, greaterThan(0));
    final err = p.stderr.transform(utf8.decoder).join();
    p.stdin.add(utf8.encode('there\n'));
    expect(await p.lines.toList(), ['hi there']);
    expect(await err, 'e\n');
    expect(await p.exitCode, 2);
    await channel.close();
  });

  test('detached process: ready line from its log, exit code, kill', () async {
    final channel = await RootChannel.connect(
      transport: transport,
      start: start,
    );
    final p = await channel.start(
      ['/bin/sh', '-c', r'echo "{\"port\":$PORT}"; sleep 30'],
      environment: {'PORT': '4000'},
      detached: true,
    );
    expect(await p.lines.first, '{"port":4000}');
    p.kill();
    expect(await p.exitCode, 143);
    await channel.close();
  });

  test('read and errors', () async {
    final channel = await RootChannel.connect(
      transport: transport,
      start: start,
    );
    await File('${moduleDir.path}/x.json').writeAsString('{}');
    expect(await channel.read('${moduleDir.path}/x.json'), '{}');
    await expectLater(
      channel.read('/etc/passwd'),
      throwsA(
        isA<RootChannelException>().having((e) => e.code, 'code', 'not-found'),
      ),
    );
    await expectLater(
      channel.start(['/nope']),
      throwsA(
        isA<RootChannelException>().having(
          (e) => e.code,
          'code',
          'start-failed',
        ),
      ),
    );
    await channel.close();
  });

  test(
    'closing the connection fails what is pending and ends attached processes',
    () async {
      final channel = await RootChannel.connect(
        transport: transport,
        start: start,
      );
      final p = await channel.start(['/bin/sleep', '30']);
      unawaited(channel.close());
      await expectLater(p.exitCode, throwsA(isA<RootChannelException>()));
      expect(channel.isClosed, isTrue);
      await expectLater(
        channel.read('/x'),
        throwsA(isA<RootChannelException>()),
      );
    },
  );
}
