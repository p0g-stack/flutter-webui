// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_webui_root/flutter_webui_root.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `root start` with tmp.config in memory and the channel started in-process
/// where the launcher would spawn `root serve --announce`.
void main() {
  late Directory moduleDir;
  late Directory runDir;
  late Directory tempDir;
  late MemoryConfig config;
  final servers = <RootChannelServer>[];
  var spawns = 0;

  Future<Stream<List<int>>> spawn() async {
    spawns++;
    final server = await RootChannelServer.start(
      moduleDir: moduleDir,
      runDir: runDir,
      store: SessionStore(config),
    );
    servers.add(server);
    return Stream.value(utf8.encode('${jsonEncode(server.info.toJson())}\n'));
  }

  ChannelLauncher launcher({ChannelSpawner? spawner}) => ChannelLauncher(
    runDir: runDir,
    tempDir: tempDir,
    config: config,
    spawn: spawner ?? spawn,
    announceTimeout: const Duration(seconds: 2),
  );

  SessionInfo session({required int pid, int port = 9, String? boot}) =>
      SessionInfo(
        protocol: protocolVersion,
        version: channelVersion,
        port: port,
        token: 'old',
        pid: pid,
        boot: boot ?? readBootId(),
        started: DateTime.utc(2026),
      );

  setUp(() async {
    moduleDir = await Directory.systemTemp.createTemp('module');
    runDir = Directory('${moduleDir.path}/flutter_webui/run');
    tempDir = Directory('${moduleDir.path}/data/tmp');
    config = MemoryConfig();
    spawns = 0;
  });

  tearDown(() async {
    for (final s in servers) {
      await s.shutdown();
    }
    servers.clear();
    await moduleDir.delete(recursive: true);
  });

  test(
    'first start of a boot empties the temp dir, later ones do not',
    () async {
      tempDir.createSync(recursive: true);
      File('${tempDir.path}/old').writeAsStringSync('x');
      Directory('${tempDir.path}/dir/sub').createSync(recursive: true);
      await launcher().run();
      expect(tempDir.listSync(), isEmpty);
      expect(config.temp[bootConfigKey], readBootId());
      expect(modeOf(tempDir.path), RunModes.dir);

      File('${tempDir.path}/new').writeAsStringSync('x');
      await launcher().run();
      expect(File('${tempDir.path}/new').existsSync(), isTrue);

      // A marker from another boot (ksud cleared it, or it is stale).
      config.temp[bootConfigKey] = 'earlier-boot';
      await launcher().run();
      expect(tempDir.listSync(), isEmpty);
    },
  );

  test('starts a channel, then reuses it', () async {
    final first = await launcher().run();
    expect(spawns, 1);
    expect(first.pid, pid);
    expect(
      config.temp[sessionConfigKey],
      jsonEncode(first.toJson()),
      reason: 'the channel keeps its session in tmp.config',
    );
    final second = await launcher().run();
    expect(spawns, 1);
    expect(second.token, first.token);
  });

  test('a session of a gone process, another boot or a closed port is '
      'replaced', () async {
    for (final stale in [
      session(pid: 0x7ffffffe),
      session(pid: pid, boot: 'earlier-boot'),
      session(pid: pid, port: 1),
    ]) {
      config.temp[sessionConfigKey] = jsonEncode(stale.toJson());
      final info = await launcher().run();
      expect(info.token, isNot('old'));
      await servers.removeLast().shutdown();
    }
    expect(spawns, 3);
  });

  test('a channel of another version is asked to shut down', () async {
    final asked = Completer<void>();
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(jsonEncode({'op': 'hello', 'version': '0.0.1', 'pid': pid}));
      socket.listen((frame) {
        if (jsonDecode(frame as String)['op'] == 'shutdown') {
          if (!asked.isCompleted) asked.complete();
          socket.close();
        }
      });
    });
    addTearDown(() => http.close(force: true));
    config.temp[sessionConfigKey] = jsonEncode(
      session(pid: pid, port: http.port).toJson(),
    );
    final info = await launcher().run();
    await asked.future.timeout(const Duration(seconds: 5));
    expect(info.port, isNot(http.port));
    expect(spawns, 1);
  });

  test('fails when the channel announces nothing', () async {
    await expectLater(
      launcher(spawner: () async => const Stream.empty()).run(),
      throwsA(isA<LauncherException>()),
    );
    await expectLater(
      launcher(spawner: () async => Stream.value(utf8.encode('not json\n')))
          .run(),
      throwsA(isA<LauncherException>()),
    );
  });
}
