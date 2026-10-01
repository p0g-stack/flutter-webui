// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webui_root/flutter_webui_root.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory moduleDir;
  late Directory webroot;
  RootChannelServer? server;

  Future<RootChannelServer> start({
    ChannelLimits limits = const ChannelLimits(),
    ChannelTimings timings = const ChannelTimings(
      killAfterTerm: Duration(milliseconds: 300),
    ),
  }) async => server = await RootChannelServer.start(
    moduleDir: moduleDir,
    limits: limits,
    timings: timings,
  );

  Future<Client> connect() async {
    final client = await Client.connect(SessionFile(webroot).read()!);
    expect((await client.next())['op'], 'hello');
    return client;
  }

  setUp(() async {
    moduleDir = await Directory.systemTemp.createTemp('module');
    webroot = Directory('${moduleDir.path}/webroot');
  });

  tearDown(() async {
    await server?.shutdown();
    server = null;
    await moduleDir.delete(recursive: true);
  });

  group('file modes', () {
    test('run directory, proc directory, session.json and lock', () async {
      // As an earlier channel left them.
      Directory('${webroot.path}/.run/proc').createSync(recursive: true);
      await setMode('${webroot.path}/.run', '755');
      await setMode('${webroot.path}/.run/proc', '755');
      File('${webroot.path}/$sessionFilePath').writeAsStringSync('{}');
      await setMode('${webroot.path}/$sessionFilePath', '666');

      final lock = (await InstanceLock.acquire(webroot))!;
      await start();
      expect(modeOf('${webroot.path}/.run'), RunModes.runDir);
      expect(modeOf('${webroot.path}/.run/proc'), RunModes.procDir);
      expect(modeOf('${webroot.path}/$sessionFilePath'), RunModes.session);
      expect(modeOf('${webroot.path}/.run/lock'), RunModes.private);
      await lock.release();
    });

    test('session.json is written through a tmp file with its mode', () async {
      final session = SessionFile(webroot);
      final info = SessionInfo(
        protocol: protocolVersion,
        version: channelVersion,
        port: 1,
        token: 't',
        pid: pid,
        boot: 'b',
        started: DateTime.utc(2026),
      );
      // A tmp file of a killed channel with this pid, world-writable.
      Directory('${webroot.path}/.run').createSync(recursive: true);
      final tmp = File('${session.file.path}.$pid.tmp')
        ..writeAsStringSync('junk');
      await setMode(tmp.path, '666');
      await session.write(info);
      expect(tmp.existsSync(), isFalse);
      expect(session.read()!.token, 't');
      expect(modeOf(session.file.path), RunModes.session);
    });

    test('detached logs and exit files are root-only', () async {
      await start();
      final client = await connect();
      client.send({
        'op': 'start',
        'id': 1,
        'detached': true,
        'argv': ['/bin/true'],
      });
      await client.nextOp('exit');
      final files = Directory('${webroot.path}/.run/proc')
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('/.boot'));
      expect(
        files.map((f) => f.path.split('.').last),
        unorderedEquals(['log', 'exit']),
      );
      for (final f in files) {
        expect(modeOf(f.path), RunModes.private, reason: f.path);
      }
      await client.close();
    });
  });

  group('stale files', () {
    SessionInfo old({
      int? pid,
      String? boot,
      String version = channelVersion,
    }) => SessionInfo(
      protocol: protocolVersion,
      version: version,
      port: 9,
      token: 'old',
      pid: pid ?? 1,
      boot: boot ?? readBootId(),
      started: DateTime.utc(2026),
    );

    test('staleReason: dead pid, other boot, other version', () {
      bool alive(int _) => true;
      bool dead(int _) => false;
      expect(
        staleReason(
          old(boot: 'b'),
          boot: 'b',
          isAlive: alive,
        ),
        isNull,
      );
      expect(
        staleReason(
          old(boot: 'a'),
          boot: 'b',
          isAlive: alive,
        ),
        contains('boot a'),
      );
      expect(
        staleReason(
          old(boot: 'b', version: '0.0.1'),
          boot: 'b',
          isAlive: alive,
        ),
        contains('0.0.1'),
      );
      expect(
        staleReason(
          old(boot: 'b', pid: 77),
          boot: 'b',
          isAlive: dead,
        ),
        contains('77'),
      );
      // The real check: this process is alive.
      expect(staleReason(old(pid: pid), boot: readBootId()), isNull);
    });

    test('a stale session.json and leftover tmp files are replaced', () async {
      final session = SessionFile(webroot);
      await session.write(old(pid: 0x7ffffffe));
      final leftover = File('${session.file.path}.12345.tmp')
        ..writeAsStringSync('{"token":"old"}');
      await start();
      final info = session.read()!;
      expect(info.pid, pid);
      expect(info.token, isNot('old'));
      expect(leftover.existsSync(), isFalse);
    });

    test('exit leaves a session.json that names another pid', () async {
      await start();
      final session = SessionFile(webroot);
      final other = old(pid: 4242);
      await session.write(other);
      await server!.shutdown();
      expect(session.read()?.pid, 4242);
    });

    test('process files of an earlier boot are removed', () async {
      final proc = Directory('${webroot.path}/.run/proc')
        ..createSync(recursive: true);
      File('${proc.path}/.boot').writeAsStringSync('earlier-boot');
      File('${proc.path}/1-0.log').writeAsStringSync('old');
      File('${proc.path}/1-0.exit.tmp').writeAsStringSync('0');
      await start();
      expect(proc.listSync().map((e) => e.uri.pathSegments.last), ['.boot']);
      expect(File('${proc.path}/.boot').readAsStringSync(), readBootId());
      await server!.shutdown();

      // Same boot: kept.
      File('${proc.path}/2-0.log').writeAsStringSync('this boot');
      await start();
      expect(File('${proc.path}/2-0.log').existsSync(), isTrue);
    });
  });

  group('limits', () {
    test('processes per connection and overall', () async {
      await start(
        limits: const ChannelLimits(processes: 3, processesPerConnection: 2),
      );
      final a = await connect();
      final b = await connect();
      for (final id in [1, 2]) {
        a.send({
          'op': 'start',
          'id': id,
          'argv': ['/bin/sleep', '30'],
        });
        await a.nextOp('started');
      }
      a.send({
        'op': 'start',
        'id': 3,
        'argv': ['/bin/sleep', '30'],
      });
      expect((await a.next())['code'], ErrorCode.tooManyProcesses);
      b.send({
        'op': 'start',
        'id': 1,
        'argv': ['/bin/sleep', '30'],
      });
      await b.nextOp('started');
      b.send({
        'op': 'start',
        'id': 2,
        'argv': ['/bin/sleep', '30'],
      });
      expect((await b.next())['code'], ErrorCode.tooManyProcesses);
      // A finished process frees its slot.
      a.send({'op': 'signal', 'id': 1, 'signal': 'KILL'});
      await a.nextOp('exit');
      b.send({
        'op': 'start',
        'id': 2,
        'argv': ['/bin/true'],
      });
      expect((await b.next())['op'], 'started');
      await a.close();
      await b.close();
    });

    test('connections', () async {
      await start(limits: const ChannelLimits(connections: 1));
      final a = await connect();
      await expectLater(
        Client.connect(SessionFile(webroot).read()!),
        throwsA(isA<WebSocketException>()),
      );
      await a.close();
      // The slot frees once the server sees the close.
      for (var i = 0; ; i++) {
        try {
          final b = await connect();
          await b.close();
          break;
        } on WebSocketException {
          if (i > 50) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    });

    test('an oversized text frame is answered, not fatal', () async {
      await start(limits: const ChannelLimits(requestBytes: 1024));
      final client = await connect();
      client.socket.add(jsonEncode({'op': 'read', 'id': 1, 'pad': 'x' * 2000}));
      expect((await client.next())['code'], ErrorCode.requestTooLarge);
      // Multi-byte characters count as their UTF-8 bytes.
      client.socket.add(jsonEncode({'op': 'read', 'id': 1, 'pad': 'é' * 600}));
      expect((await client.next())['code'], ErrorCode.requestTooLarge);
      File('${moduleDir.path}/f').writeAsStringSync('ok');
      client.send({'op': 'read', 'id': 2, 'path': '${moduleDir.path}/f'});
      expect((await client.next())['data'], 'ok');
      await client.close();
    });

    test('argv and env size and shape', () async {
      await start(limits: const ChannelLimits(argvEnvBytes: 1000));
      final client = await connect();
      client.send({
        'op': 'start',
        'id': 1,
        'argv': ['/bin/echo', 'x' * 600],
        'env': {'BIG': 'y' * 600},
      });
      expect((await client.next())['code'], ErrorCode.requestTooLarge);
      for (final bad in <Map<String, Object?>>[
        {
          'argv': ['/bin/echo', 'a\u0000b'],
        },
        {
          'argv': [''],
        },
        {
          'argv': ['/bin/true'],
          'env': {'A=B': 'c'},
        },
        {
          'argv': ['/bin/true'],
          'env': {'': 'c'},
        },
        {
          'argv': ['/bin/true'],
          'env': {'A': 'c\u0000'},
        },
        {
          'argv': ['/bin/true'],
          'cwd': 'relative/dir',
        },
      ]) {
        client.send({'op': 'start', 'id': 2, ...bad});
        expect(
          (await client.next())['code'],
          ErrorCode.badRequest,
          reason: '$bad',
        );
      }
      client.send({
        'op': 'start',
        'id': 3,
        'argv': ['/bin/true'],
        'cwd': '${moduleDir.path}/missing',
      });
      expect((await client.next())['code'], ErrorCode.startFailed);
      await client.close();
    });

    test('stdin held for a process that does not read is capped', () async {
      await start(limits: const ChannelLimits(stdinBufferBytes: 64 * 1024));
      final client = await connect();
      client.send({
        'op': 'start',
        'id': 1,
        'argv': ['/bin/sleep', '30'],
      });
      await client.nextOp('started');
      final chunk = Uint8List(16 * 1024);
      // Past the pipe buffer (64 KiB on Linux) plus the cap.
      for (var i = 0; i < 64; i++) {
        client.socket.add(DataFrame(StreamTag.stdin, 1, chunk).encode());
      }
      final error = await client.nextOp('error');
      expect(error['code'], ErrorCode.stdinOverflow);
      expect(error['id'], 1);
      client.send({'op': 'signal', 'id': 1, 'signal': 'KILL'});
      expect((await client.nextOp('exit'))['code'], -9);
      await client.close();
    });

    test('stdin a process reads is never capped', () async {
      await start(limits: const ChannelLimits(stdinBufferBytes: 64 * 1024));
      final client = await connect();
      var received = 0;
      client.data.listen((f) => received += f.payload.length);
      client.send({
        'op': 'start',
        'id': 1,
        'argv': ['/bin/cat'],
      });
      await client.nextOp('started');
      // One frame larger than the cap, while nothing waits, is taken whole.
      final big = Uint8List(256 * 1024);
      client.socket.add(DataFrame(StreamTag.stdin, 1, big).encode());
      while (received < big.length) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final chunk = Uint8List(16 * 1024);
      for (var i = 0; i < 64; i++) {
        client.socket.add(DataFrame(StreamTag.stdin, 1, chunk).encode());
        // Paced, as a page writing a large file would be.
        while (received < big.length + (i - 1) * chunk.length) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      client.send({'op': 'close-stdin', 'id': 1});
      final exit = await client.nextOp('exit');
      expect(exit['code'], 0);
      expect(received, big.length + 64 * chunk.length);
      await client.close();
    });
  });

  group('robustness', () {
    test('a duplicate id sent before the first start finishes', () async {
      await start();
      final client = await connect();
      for (var i = 0; i < 2; i++) {
        client.send({
          'op': 'start',
          'id': 5,
          'argv': ['/bin/sleep', '30'],
        });
      }
      final answers = [await client.next(), await client.next()];
      expect(
        answers.map((m) => m['op'] == 'started' ? 'started' : m['code']),
        unorderedEquals(['started', ErrorCode.duplicateId]),
      );
      await client.close();
    });

    test('a process started as its owner leaves is ended', () async {
      await start(
        timings: const ChannelTimings(
          idleExit: Duration(milliseconds: 200),
          killAfterTerm: Duration(milliseconds: 300),
        ),
      );
      final pidFile = File('${moduleDir.path}/child.pid');
      final client = await connect();
      client.send({
        'op': 'start',
        'id': 1,
        'argv': ['/bin/sh', '-c', 'echo \$\$ > ${pidFile.path}; exec sleep 30'],
      });
      await client.socket.close();
      // Nothing may keep the channel alive once the child is ended.
      await server!.done.timeout(const Duration(seconds: 5));
      for (var i = 0; !pidFile.existsSync() && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (pidFile.existsSync()) {
        final text = pidFile.readAsStringSync().trim();
        if (text.isNotEmpty) await waitGone(int.parse(text));
      }
    });

    test('read refuses a FIFO without blocking', () async {
      await start();
      final client = await connect();
      final fifo = '${moduleDir.path}/fifo';
      expect((await Process.run('mkfifo', [fifo])).exitCode, 0);
      client.send({'op': 'read', 'id': 1, 'path': fifo});
      expect((await client.next())['code'], ErrorCode.notFound);
      client.send({'op': 'read', 'id': 2, 'path': moduleDir.path});
      expect((await client.next())['code'], ErrorCode.notFound);
      await client.close();
    });

    test('read follows symlinks only inside the module', () async {
      await start();
      final client = await connect();
      final outside = File(
        '${moduleDir.parent.path}/outside-${moduleDir.uri.pathSegments.where((s) => s.isNotEmpty).last}',
      )..writeAsStringSync('secret');
      addTearDown(outside.deleteSync);
      Link('${moduleDir.path}/escape').createSync(outside.path);
      Link('${moduleDir.path}/inside').createSync('${moduleDir.path}/webroot');
      File('${webroot.path}/f').writeAsStringSync('ok');
      client.send({'op': 'read', 'id': 1, 'path': '${moduleDir.path}/escape'});
      expect((await client.next())['code'], ErrorCode.notFound);
      client.send({
        'op': 'read',
        'id': 2,
        'path': '${moduleDir.path}/inside/f',
      });
      expect((await client.next())['data'], 'ok');
      await client.close();
    });

    test('a token of the right length but wrong value is refused', () async {
      await start();
      final info = SessionFile(webroot).read()!;
      final forged = info.token.replaceRange(
        0,
        1,
        info.token[0] == 'A' ? 'B' : 'A',
      );
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:${info.port}/v1?token=$forged'),
        throwsA(isA<WebSocketException>()),
      );
    });

    test('broken and aborted requests do not end the channel', () async {
      await start();
      final info = SessionFile(webroot).read()!;
      for (final request in [
        'GET /v1?token=%zz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n',
        'GET /v1?token=${info.token} HTTP/1.1\r\nHost: 127.0.0.1\r\n'
            'Connection: Upgrade\r\nUpgrade: websocket\r\n'
            'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: x\r\n\r\n',
        'garbage\r\n\r\n',
        'GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n',
      ]) {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          info.port,
        );
        socket.write(request);
        await socket.flush();
        socket.destroy();
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final client = await connect();
      await client.close();
    });

    test('a second Origin header is refused', () async {
      await start();
      final info = SessionFile(webroot).read()!;
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        info.port,
      );
      socket.write(
        'GET /v1?token=${info.token} HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Origin: $managerOrigin\r\nOrigin: https://evil.example\r\n'
        'Connection: Upgrade\r\nUpgrade: websocket\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n',
      );
      final response = await utf8.decoder.bind(socket).first;
      expect(response, startsWith('HTTP/1.1 403'));
      socket.destroy();
    });

    test('no permessage-deflate', () async {
      await start();
      final info = SessionFile(webroot).read()!;
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        info.port,
      );
      socket.write(
        'GET /v1?token=${info.token} HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Connection: Upgrade\r\nUpgrade: websocket\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n',
      );
      final response = await latin1.decoder.bind(socket).first;
      expect(response, startsWith('HTTP/1.1 101'));
      expect(response.toLowerCase(), isNot(contains('permessage-deflate')));
      socket.destroy();
    });
  });
}
