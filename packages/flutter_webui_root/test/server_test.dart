// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:convert';
import 'dart:io';

import 'package:flutter_webui_root/flutter_webui_root.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory moduleDir;
  late Directory webroot;
  late RootChannelServer server;

  Future<RootChannelServer> startServer({ChannelTimings? timings}) =>
      RootChannelServer.start(
        moduleDir: moduleDir,
        timings:
            timings ??
            const ChannelTimings(
              idleExit: Duration(seconds: 30),
              killAfterTerm: Duration(milliseconds: 300),
            ),
      );

  setUp(() async {
    moduleDir = await Directory.systemTemp.createTemp('module');
    webroot = Directory('${moduleDir.path}/webroot');
    server = await startServer();
  });

  tearDown(() async {
    await server.shutdown();
    await moduleDir.delete(recursive: true);
  });

  test('publishes session.json and greets', () async {
    final info = SessionFile(webroot).read()!;
    expect(info.port, server.port);
    expect(info.protocol, protocolVersion);
    expect(info.token, hasLength(43));
    final client = await Client.connect(info);
    final hello = await client.next();
    expect(hello['op'], 'hello');
    expect(hello['protocol'], protocolVersion);
    expect(hello['version'], channelVersion);
    await client.close();
  });

  test('rejects a wrong token and a foreign origin', () async {
    final info = SessionFile(webroot).read()!;
    final wrong = Uri.parse('ws://127.0.0.1:${info.port}/v1?token=nope');
    await expectLater(
      WebSocket.connect(wrong.toString()),
      throwsA(isA<WebSocketException>()),
    );
    await expectLater(
      Client.connect(info, origin: 'https://evil.example'),
      throwsA(isA<WebSocketException>()),
    );
    final noOrigin = await Client.connect(info, origin: null);
    expect((await noOrigin.next())['op'], 'hello');
    await noOrigin.close();
  });

  test('runs a process with stdin, stdout, stderr and exit code', () async {
    final client = await Client.connect(SessionFile(webroot).read()!);
    await client.next();
    final out = <int>[];
    final err = <int>[];
    client.data.listen(
      (f) => (f.stream == StreamTag.stdout ? out : err).addAll(f.payload),
    );
    client.send({
      'op': 'start',
      'id': 7,
      'argv': [
        '/bin/sh',
        '-c',
        r'read x; echo "got $x"; echo oops >&2; exit 3',
      ],
    });
    final started = await client.next();
    expect(started['op'], 'started');
    expect(started['pid'], isA<int>());
    client.stdin(7, 'hello\n');
    final exit = await client.nextOp('exit');
    expect(exit, {'op': 'exit', 'id': 7, 'code': 3});
    expect(utf8.decode(out), 'got hello\n');
    expect(utf8.decode(err), 'oops\n');
    await client.close();
  });

  test('close-stdin delivers EOF and env/cwd apply', () async {
    final client = await Client.connect(SessionFile(webroot).read()!);
    await client.next();
    final out = <int>[];
    client.data.listen((f) => out.addAll(f.payload));
    client.send({
      'op': 'start',
      'id': 1,
      'argv': ['/bin/sh', '-c', r'cat; echo "$FOO $(pwd)"'],
      'env': {'FOO': 'bar'},
      'cwd': moduleDir.path,
    });
    await client.nextOp('started');
    client.stdin(1, 'abc');
    client.send({'op': 'close-stdin', 'id': 1});
    expect((await client.nextOp('exit'))['code'], 0);
    expect(
      utf8.decode(out),
      'abcbar ${moduleDir.resolveSymbolicLinksSync()}\n',
    );
    await client.close();
  });

  test('signals and start errors', () async {
    final client = await Client.connect(SessionFile(webroot).read()!);
    await client.next();
    client.send({
      'op': 'start',
      'id': 1,
      'argv': ['/does/not/exist'],
    });
    expect((await client.next())['code'], ErrorCode.startFailed);
    client.send({
      'op': 'start',
      'id': 2,
      'argv': ['/bin/sleep', '30'],
    });
    await client.nextOp('started');
    client.send({
      'op': 'start',
      'id': 2,
      'argv': ['/bin/true'],
    });
    expect((await client.next())['code'], ErrorCode.duplicateId);
    client.send({'op': 'signal', 'id': 2, 'signal': 'KILL'});
    expect((await client.nextOp('exit'))['code'], -9);
    client.send({'op': 'signal', 'id': 2, 'signal': 'TERM'});
    expect((await client.next())['code'], ErrorCode.noSuchProcess);
    client.send({'op': 'bogus', 'id': 3});
    expect((await client.next())['code'], ErrorCode.badRequest);
    await client.close();
  });

  test('owner lost ends a piped process', () async {
    final info = SessionFile(webroot).read()!;
    final client = await Client.connect(info);
    await client.next();
    client.send({
      'op': 'start',
      'id': 1,
      'argv': ['/bin/sleep', '30'],
    });
    final pid = (await client.nextOp('started'))['pid'] as int;
    await client.close();
    await waitGone(pid);
  });

  test('streams large output without loss', () async {
    final client = await Client.connect(SessionFile(webroot).read()!);
    await client.next();
    var received = 0;
    client.data.listen((f) => received += f.payload.length);
    client.send({
      'op': 'start',
      'id': 1,
      'argv': ['/bin/sh', '-c', 'head -c 8388608 /dev/zero'],
    });
    expect((await client.nextOp('exit'))['code'], 0);
    expect(received, 8388608);
    await client.close();
  });

  test(
    'a detached process streams its log, reports exit, outlives its owner',
    () async {
      final info = SessionFile(webroot).read()!;
      final client = await Client.connect(info);
      await client.next();
      final out = StringBuffer();
      client.data.listen((f) {
        expect(f.stream, StreamTag.stdout);
        out.write(utf8.decode(f.payload));
      });
      client.send({
        'op': 'start',
        'id': 1,
        'detached': true,
        'argv': ['/bin/sh', '-c', r'echo "ready $FOO"; echo err >&2; exit 4'],
        'env': {'FOO': 'bar'},
      });
      await client.nextOp('started');
      expect(await client.nextOp('exit'), {'op': 'exit', 'id': 1, 'code': 4});
      expect(out.toString(), 'ready bar\nerr\n');

      client.send({
        'op': 'start',
        'id': 2,
        'detached': true,
        'argv': ['/bin/sh', '-c', r'echo $$; exec sleep 30'],
      });
      await client.nextOp('started');
      final line = await client.data.first;
      final sleeper = int.parse(utf8.decode(line.payload).trim());
      await client.close();
      await server.shutdown();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(File('/proc/$sleeper/stat').existsSync(), isTrue);
      Process.killPid(sleeper, ProcessSignal.sigkill);
    },
  );

  test('signal reaches a detached process group', () async {
    final client = await Client.connect(SessionFile(webroot).read()!);
    await client.next();
    client.send({
      'op': 'start',
      'id': 1,
      'detached': true,
      'argv': ['/bin/sleep', '30'],
    });
    await client.nextOp('started');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    client.send({'op': 'signal', 'id': 1, 'signal': 'TERM'});
    expect((await client.nextOp('exit'))['code'], 143);
    await client.close();
  });

  test('read returns small files inside the module only', () async {
    final client = await Client.connect(SessionFile(webroot).read()!);
    await client.next();
    File('${moduleDir.path}/place.json').writeAsStringSync('{"port":1}');
    client.send({
      'op': 'read',
      'id': 1,
      'path': '${moduleDir.path}/place.json',
    });
    expect(await client.next(), {'op': 'read', 'id': 1, 'data': '{"port":1}'});
    client.send({
      'op': 'read',
      'id': 2,
      'path': '${moduleDir.path}/../outside',
    });
    expect((await client.next())['code'], ErrorCode.notFound);
    client.send({'op': 'read', 'id': 3, 'path': '/etc/hostname'});
    expect((await client.next())['code'], ErrorCode.notFound);
    File('${moduleDir.path}/big')
        .writeAsBytesSync(List.filled(maxReadBytes + 1, 65));
    client.send({'op': 'read', 'id': 4, 'path': '${moduleDir.path}/big'});
    expect((await client.next())['code'], ErrorCode.tooLarge);
    await client.close();
  });

  test('exits when idle and removes session.json', () async {
    await server.shutdown();
    server = await startServer(
      timings: const ChannelTimings(idleExit: Duration(milliseconds: 200)),
    );
    expect(SessionFile(webroot).read(), isNotNull);
    await server.done.timeout(const Duration(seconds: 5));
    expect(SessionFile(webroot).read(), isNull);
  });

  test('shutdown op ends piped processes', () async {
    final client = await Client.connect(SessionFile(webroot).read()!);
    await client.next();
    client.send({
      'op': 'start',
      'id': 1,
      'argv': ['/bin/sleep', '30'],
    });
    final pid = (await client.nextOp('started'))['pid'] as int;
    client.send({'op': 'shutdown', 'id': 2});
    await server.done.timeout(const Duration(seconds: 5));
    await waitGone(pid);
  });
}
