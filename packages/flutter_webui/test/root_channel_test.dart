// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webui/flutter_webui.dart';
import 'package:flutter_webui/src/io_transport.dart';
import 'package:flutter_webui_root/flutter_webui_root.dart';

/// The page client against the real channel, started in-process where the
/// bridge would run `root start`.
void main() {
  late Directory moduleDir;
  late IoChannelTransport transport;
  RootChannelServer? server;
  var starts = 0;

  Future<void> start() async {
    starts++;
    server = await RootChannelServer.start(moduleDir: moduleDir);
  }

  setUp(() async {
    moduleDir = await Directory.systemTemp.createTemp('module');
    transport = IoChannelTransport(
      File('${moduleDir.path}/webroot/.run/session.json'),
      origin: managerOrigin,
    );
    starts = 0;
    server = null;
  });

  tearDown(() async {
    await server?.shutdown();
    await moduleDir.delete(recursive: true);
  });

  test('starts the channel when there is none, then reuses it', () async {
    final first = await RootChannel.connect(transport: transport, start: start);
    expect(starts, 1);
    expect(first.moduleDir, moduleDir.absolute.path);
    await first.close();
    final second = await RootChannel.connect(
      transport: transport,
      start: start,
    );
    expect(starts, 1);
    expect(second.session.pid, first.session.pid);
    await second.close();
  });

  test('a stale session file is replaced', () async {
    await Directory('${moduleDir.path}/webroot/.run').create(recursive: true);
    await File('${moduleDir.path}/webroot/.run/session.json').writeAsString(
      jsonEncode({
        'protocol': 1,
        'version': channelVersion,
        'port': 1,
        'token': 'x',
        'pid': 999999,
        'boot': 'old',
        'started': '2026-01-01T00:00:00Z',
      }),
    );
    final channel = await RootChannel.connect(
      transport: transport,
      start: start,
    );
    expect(starts, 1);
    expect(channel.session.pid, pid);
    await channel.close();
  });

  test('fails clearly when the channel never starts', () async {
    await expectLater(
      RootChannel.connect(
        transport: transport,
        start: () async {},
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(
        isA<RootChannelException>().having(
          (e) => e.code,
          'code',
          'unavailable',
        ),
      ),
    );
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

  test('a channel of another version is shut down and replaced', () async {
    await start();
    final old = server!;
    final info = SessionFile(Directory('${moduleDir.path}/webroot')).read()!;
    // Rewrite the session file as if an older channel wrote it.
    await SessionFile(Directory('${moduleDir.path}/webroot')).write(
      SessionInfo(
        protocol: 1,
        version: '0.0.1',
        port: info.port,
        token: info.token,
        pid: 424242,
        boot: info.boot,
        started: info.started,
      ),
    );
    final channel = await RootChannel.connect(
      transport: transport,
      start: start,
    );
    await old.done.timeout(const Duration(seconds: 5));
    expect(starts, 2);
    expect(channel.session.version, channelVersion);
    await channel.close();
  });
}
