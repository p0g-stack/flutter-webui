// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_webui_root/flutter_webui_root.dart';

const String _usage =
    'Usage: flutter_webui_root start|serve --module-dir <dir> [options]';

Future<void> main(List<String> arguments) async {
  ArgParser common() => ArgParser()
    ..addOption(
      'module-dir',
      help: 'The module directory (/data/adb/modules/<id>).',
      mandatory: true,
    )
    ..addOption('module-id', help: 'Defaults to the module directory name.')
    ..addOption(
      'run-dir',
      help:
          'Lock, logs and detached-process files '
          '(default <module-dir>/flutter_webui/run).',
    )
    ..addOption(
      'temp-dir',
      help:
          'The module TMPDIR, emptied on the first start of a boot '
          '(default /data/adb/<id>/tmp).',
    );
  final parser = ArgParser()
    ..addCommand(
      'start',
      common()..addOption(
        'launcher',
        help: 'The launcher script, run as `sh <launcher> serve`.',
        mandatory: true,
      ),
    )
    ..addCommand(
      'serve',
      common()
        ..addOption(
          'idle-exit',
          help: 'Seconds without connections or processes before exiting.',
          defaultsTo: '30',
        )
        ..addFlag(
          'announce',
          help: 'Print the session on stdout once listening, then close it.',
          negatable: false,
        ),
    )
    ..addFlag('version', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$_usage');
    exit(64);
  }
  if (args.flag('version')) {
    stdout.writeln(
      'flutter_webui_root $channelVersion (protocol $protocolVersion)',
    );
    return;
  }
  final command = args.command;
  if (command == null) {
    stderr.writeln(_usage);
    exit(64);
  }
  final moduleDir = Directory(command.option('module-dir')!).absolute;
  final moduleId =
      command.option('module-id') ??
      moduleDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  final runDir = Directory(
    command.option('run-dir') ?? '${moduleDir.path}/flutter_webui/run',
  );
  final tempDir = Directory(
    command.option('temp-dir') ?? '/data/adb/$moduleId/tmp',
  );
  final config = KsudModuleConfig(moduleId);
  void log(String message) =>
      stderr.writeln('${DateTime.now().toIso8601String()} $message');

  switch (command.name) {
    case 'start':
      await _start(command, runDir, tempDir, config, log);
    case 'serve':
      await _serve(command, moduleId, moduleDir, runDir, config, log);
  }
}

/// Prints the session as one line and exits 0, or a message on stderr and
/// exits 1.
Future<void> _start(
  ArgResults command,
  Directory runDir,
  Directory tempDir,
  ModuleConfig config,
  void Function(String) log,
) async {
  final launcher = command.option('launcher')!;
  final launcherLog = StringBuffer();
  try {
    final info = await ChannelLauncher(
      runDir: runDir,
      tempDir: tempDir,
      config: config,
      log: (m) => launcherLog.writeln(m),
      spawn: () async {
        // Detached (own session, survives this launcher and the manager's
        // shell); only stdout is used, for the announce line. The launcher
        // script takes stdin from /dev/null and sends stderr to root.log.
        final process = await Process.start(_sh(), [
          launcher,
          'serve',
        ], mode: ProcessStartMode.detachedWithStdio);
        unawaited(process.stdin.close());
        unawaited(process.stderr.drain<void>());
        return process.stdout;
      },
    ).run();
    stdout.writeln(jsonEncode(info.toJson()));
    await stdout.flush();
    exit(0);
  } on Object catch (e) {
    stderr.write(launcherLog);
    stderr.writeln('flutter_webui: $e (see ${runDir.path}/root.log)');
    exit(1);
  }
}

Future<void> _serve(
  ArgResults command,
  String moduleId,
  Directory moduleDir,
  Directory runDir,
  ModuleConfig config,
  void Function(String) log,
) async {
  final idle = int.tryParse(command.option('idle-exit')!) ?? 30;
  final lock = await InstanceLock.acquire(
    runDir,
    wait: const Duration(seconds: 10),
  );
  if (lock == null) {
    log('another channel is running for ${moduleDir.path}');
    exit(1);
  }
  // The launcher appends; the log holds only the running channel's output.
  final rootLog = File('${runDir.path}/root.log');
  try {
    if (rootLog.existsSync()) {
      rootLog.writeAsStringSync('');
      await setMode(rootLog.path, RunModes.private);
    }
  } on FileSystemException {
    // Started by hand, not through the launcher.
  }
  final RootChannelServer server;
  try {
    server = await RootChannelServer.start(
      moduleDir: moduleDir,
      runDir: runDir,
      store: SessionStore(config),
      timings: ChannelTimings(idleExit: Duration(seconds: idle)),
      log: log,
    );
  } on Object catch (e) {
    log('could not start: $e');
    exit(1);
  }
  if (command.flag('announce')) {
    stdout.writeln(jsonEncode(server.info.toJson()));
    await stdout.flush();
    // The launcher reads one line and goes away; nothing else is written.
    await stdout.close();
  }
  // Keeps the module's app unfrozen while the channel runs; after the
  // announce so the page does not wait on `am`.
  final keepAlive = AppPlaneKeepAlive(moduleId, log: log);
  unawaited(keepAlive.hold());
  for (final signal in [
    ProcessSignal.sigterm,
    ProcessSignal.sigint,
    ProcessSignal.sighup,
  ]) {
    signal.watch().listen((_) {
      // SIGHUP: survive the manager's shell closing.
      if (signal == ProcessSignal.sighup) return;
      unawaited(server.shutdown());
    });
  }
  await server.done;
  await keepAlive.release();
  await lock.release();
  exit(0);
}

String _sh() =>
    File('/system/bin/sh').existsSync() ? '/system/bin/sh' : '/bin/sh';
