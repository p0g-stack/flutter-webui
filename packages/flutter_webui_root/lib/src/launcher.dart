// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'run_state.dart';

/// Starts a channel (`root serve --announce`) detached and returns its
/// stdout, whose first line is the session.
typedef ChannelSpawner = Future<Stream<List<int>>> Function();

/// `root start`: finds the module's running channel or starts one, and
/// returns its session, the line the launcher prints. See "Start" in
/// `docs/root-channel.md`.
///
/// Under `start.lock` in [runDir]:
/// 1. Boot marker: if tmp.config's [bootConfigKey] is not this boot (ksud
///    clears tmp.config each boot), empties [tempDir] and sets it.
/// 2. The session in tmp.config, if any, is used when a hello with its token
///    answers with this channel version. A channel of another version is
///    asked to shut down.
/// 3. Otherwise [spawn] starts a channel, which writes its session to
///    tmp.config and announces it on stdout once it listens.
final class ChannelLauncher {
  ChannelLauncher({
    required this.runDir,
    required this.tempDir,
    required this.config,
    required this.spawn,
    this.log = _noLog,
    this.announceTimeout = const Duration(seconds: 15),
  });

  final Directory runDir;

  /// The module's temporary directory (`/data/adb/<id>/tmp`, the TMPDIR of
  /// the channel and what it starts).
  final Directory tempDir;
  final ModuleConfig config;
  final ChannelSpawner spawn;
  final void Function(String) log;
  final Duration announceTimeout;

  Future<SessionInfo> run() async {
    final lock = await StartLock.acquire(runDir);
    try {
      final boot = readBootId();
      await _bootMarker(boot);
      final store = SessionStore(config);
      final previous = await store.read();
      if (previous != null) {
        final live = await _probe(previous, boot);
        if (live != null) return live;
      }
      return await _startChannel();
    } finally {
      await lock.release();
    }
  }

  Future<void> _bootMarker(String boot) async {
    if (await config.get(bootConfigKey) == boot) return;
    await tempDir.create(recursive: true);
    await setMode(tempDir.path, RunModes.dir);
    var removed = 0;
    await for (final entry in tempDir.list(followLinks: false)) {
      try {
        await entry.delete(recursive: true);
        removed++;
      } on FileSystemException catch (e) {
        log('temp: $e');
      }
    }
    log('first start of boot $boot: emptied ${tempDir.path} ($removed)');
    await config.setTemp(bootConfigKey, boot);
  }

  /// The session if its channel answers the hello with this version; asks a
  /// channel of another version to shut down. Null otherwise.
  Future<SessionInfo?> _probe(SessionInfo info, String boot) async {
    if (info.boot != boot || !pidAlive(info.pid)) {
      log('session of pid ${info.pid}: ${staleReason(info, boot: boot)}');
      return null;
    }
    WebSocket socket;
    try {
      socket = await WebSocket.connect(info.uri.toString())
          .timeout(const Duration(seconds: 2));
    } on Object catch (e) {
      log('session of pid ${info.pid} does not answer: $e');
      return null;
    }
    try {
      final first = await socket.first.timeout(const Duration(seconds: 2));
      final hello = first is String ? jsonDecode(first) : null;
      if (hello is! Map || hello['op'] != 'hello' || hello['pid'] != info.pid) {
        log('session of pid ${info.pid}: no hello');
        return null;
      }
      if (hello['version'] == channelVersion) return info;
      log('channel of pid ${info.pid} is version ${hello['version']}');
    } on Object catch (e) {
      log('session of pid ${info.pid}: $e');
      return null;
    } finally {
      // `first` cancelled the subscription, which closes the socket.
      unawaited(socket.close().catchError((Object _) {}));
    }
    await _shutdown(info);
    return null;
  }

  Future<void> _shutdown(SessionInfo info) async {
    try {
      final socket = await WebSocket.connect(info.uri.toString());
      socket.add(jsonEncode({'op': 'shutdown', 'id': 1}));
      await socket.drain<void>().timeout(const Duration(seconds: 5));
    } on Object catch (e) {
      log('shutdown of pid ${info.pid}: $e');
    }
  }

  Future<SessionInfo> _startChannel() async {
    // A channel that runs without a usable session (tmp.config lost it, or
    // it never answered) cannot be reached: end it, so the new one gets the
    // lock instead of waiting for it to go idle.
    final orphan = InstanceLock.holder(runDir);
    if (orphan != null) {
      log('ending channel pid $orphan, which has no usable session');
      Process.killPid(orphan, ProcessSignal.sigterm);
    }
    final out = await spawn();
    final String line;
    try {
      line = await out
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(announceTimeout);
    } on Object catch (e) {
      throw LauncherException('the channel did not announce a session: $e');
    }
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      throw LauncherException('the channel announced: $line');
    }
    final info = SessionInfo.fromJson(json);
    if (info == null) throw LauncherException('the channel announced: $line');
    return info;
  }
}

final class LauncherException implements Exception {
  const LauncherException(this.message);

  final String message;

  @override
  String toString() => message;
}

void _noLog(String _) {}
