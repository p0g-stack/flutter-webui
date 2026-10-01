// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_webui_root/flutter_webui_root.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addCommand(
      'serve',
      ArgParser()
        ..addOption(
          'module-dir',
          help: 'The module directory (holds webroot/).',
          mandatory: true,
        )
        ..addOption(
          'idle-exit',
          help: 'Seconds without connections or processes before exiting.',
          defaultsTo: '30',
        ),
    )
    ..addFlag('version', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(
      '${e.message}\n\nUsage: flutter_webui_root serve --module-dir <dir>\n${parser.commands['serve']!.usage}',
    );
    exit(64);
  }
  if (args.flag('version')) {
    stdout.writeln(
      'flutter_webui_root $channelVersion (protocol $protocolVersion)',
    );
    return;
  }
  final serve = args.command;
  if (serve == null || serve.name != 'serve') {
    stderr.writeln('Usage: flutter_webui_root serve --module-dir <dir>');
    exit(64);
  }
  final moduleDir = Directory(serve.option('module-dir')!);
  final webroot = Directory('${moduleDir.path}/webroot');
  final idle = int.tryParse(serve.option('idle-exit')!) ?? 30;
  void log(String message) =>
      stderr.writeln('${DateTime.now().toIso8601String()} $message');

  final lock = await InstanceLock.acquire(webroot);
  if (lock == null) {
    log('another channel is running for ${webroot.path}');
    return;
  }
  // The launcher appends; the log holds only the running channel's output.
  try {
    File('${webroot.path}/.run/root.log').writeAsStringSync('');
  } on FileSystemException {
    // Started by hand, not through the launcher.
  }
  final server = await RootChannelServer.start(
    moduleDir: moduleDir,
    timings: ChannelTimings(idleExit: Duration(seconds: idle)),
    log: log,
  );
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
  await lock.release();
  exit(0);
}
