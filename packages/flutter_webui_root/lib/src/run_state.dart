// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';

/// File modes of what the channel keeps in its run directory
/// (`<moddir>/flutter_webui/run/`; octal strings, as `chmod` takes them). See
/// "Files" in `docs/root-channel.md`.
abstract final class RunModes {
  /// The run directory and `proc/`: root-only.
  static const String dir = '700';

  /// `lock`, `start.lock`, `root.log`, detached-process logs and exit files.
  static const String private = '600';
}

/// Sets [path]'s mode with the system `chmod` (`dart:io` has none). Returns
/// false if it could not.
Future<bool> setMode(String path, String mode) async {
  try {
    final result = await Process.run(_chmod(), [mode, path]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

String _chmod() {
  for (final path in const ['/system/bin/chmod', '/bin/chmod']) {
    if (File(path).existsSync()) return path;
  }
  return 'chmod';
}

/// Creates the run directory and its `proc/`, and sets their modes.
Future<void> prepareRunDir(Directory runDir) async {
  final procDir = Directory('${runDir.path}/proc');
  await procDir.create(recursive: true);
  await setMode(runDir.path, RunModes.dir);
  await setMode(procDir.path, RunModes.dir);
}

/// Why [info], the session found in tmp.config, cannot be used: another boot,
/// another channel version, or its process is gone. Null if it may be live
/// (the launcher still checks the hello).
String? staleReason(
  SessionInfo info, {
  required String boot,
  bool Function(int pid) isAlive = pidAlive,
}) {
  if (info.boot != boot) return 'written in boot ${info.boot}';
  if (info.version != channelVersion) return 'version ${info.version}';
  if (!isAlive(info.pid)) return 'pid ${info.pid} is gone';
  return null;
}

/// Whether a process [pid] exists (`/proc/<pid>`; true off Linux).
bool pidAlive(int pid) {
  if (!Directory('/proc/self').existsSync()) return true;
  return Directory('/proc/$pid').existsSync();
}

/// `/proc/sys/kernel/random/boot_id`, or `unknown` off Linux.
String readBootId() {
  try {
    return File('/proc/sys/kernel/random/boot_id').readAsStringSync().trim();
  } on FileSystemException {
    return 'unknown';
  }
}

/// Holds `lock` in the run directory while a channel runs, so a second
/// channel of the module exits at once.
final class InstanceLock {
  InstanceLock._(this._file);

  final RandomAccessFile _file;

  /// Returns null if another channel still holds the lock after [wait] (a
  /// channel that is shutting down releases it within moments).
  static Future<InstanceLock?> acquire(
    Directory runDir, {
    Duration wait = Duration.zero,
  }) async {
    await prepareRunDir(runDir);
    final path = '${runDir.path}/lock';
    final file = await File(path).open(mode: FileMode.append);
    if (!await _tryLock(file, wait)) {
      await file.close();
      return null;
    }
    await setMode(path, RunModes.private);
    // Who holds it, for a launcher that finds the channel without a session.
    await file.truncate(0);
    await file.setPosition(0);
    await file.writeString('$pid\n');
    await file.flush();
    return InstanceLock._(file);
  }

  /// The pid of the channel holding the lock in [runDir], if that process
  /// still runs and is a channel (its command line names
  /// `flutter_webui_root`). Null otherwise.
  static int? holder(Directory runDir) {
    final int? holder;
    try {
      holder = int.tryParse(
        File('${runDir.path}/lock').readAsStringSync().trim(),
      );
    } on FileSystemException {
      return null;
    }
    if (holder == null || holder == pid) return null;
    try {
      final cmdline = File('/proc/$holder/cmdline').readAsStringSync();
      return cmdline.contains('flutter_webui_root') ? holder : null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> release() async {
    await _file.unlock();
    await _file.close();
  }
}

/// `start.lock` in the run directory: one launcher at a time checks the boot
/// marker, finds or starts the channel and prints its session.
final class StartLock {
  StartLock._(this._file);

  final RandomAccessFile _file;

  /// Waits for the lock; throws [TimeoutException] after [timeout].
  static Future<StartLock> acquire(
    Directory runDir, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await prepareRunDir(runDir);
    final path = '${runDir.path}/start.lock';
    final file = await File(path).open(mode: FileMode.append);
    await setMode(path, RunModes.private);
    if (!await _tryLock(file, timeout)) {
      await file.close();
      throw TimeoutException('start.lock is held', timeout);
    }
    return StartLock._(file);
  }

  Future<void> release() async {
    await _file.unlock();
    await _file.close();
  }
}

/// The module's config in KernelSU (`ksud module config`, KernelSU and
/// KernelSU Next v3.0.0+), as the module itself: `KSU_MODULE=<id>`.
/// Only temporary entries (tmp.config, which ksud clears each boot).
abstract interface class ModuleConfig {
  /// The value of [key], or null if it is not set.
  Future<String?> get(String key);

  Future<void> setTemp(String key, String value);

  Future<void> deleteTemp(String key);
}

/// [ModuleConfig] through the `ksud` executable.
final class KsudModuleConfig implements ModuleConfig {
  KsudModuleConfig(this.moduleId, {String? ksud}) : ksud = ksud ?? findKsud();

  final String moduleId;
  final String ksud;

  /// `$FLUTTER_WEBUI_KSUD` (tests, the fake host), else KernelSU's paths.
  static String findKsud() {
    final override = Platform.environment['FLUTTER_WEBUI_KSUD'];
    if (override != null && override.isNotEmpty) return override;
    for (final path in const ['/data/adb/ksud', '/data/adb/ksu/bin/ksud']) {
      if (File(path).existsSync()) return path;
    }
    return 'ksud';
  }

  Future<ProcessResult> _run(List<String> args, {String? stdin}) async {
    final process = await Process.start(
      ksud,
      ['module', 'config', ...args],
      environment: {'KSU_MODULE': moduleId},
    );
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    return ProcessResult(
      process.pid,
      await process.exitCode,
      await out,
      await err,
    );
  }

  @override
  Future<String?> get(String key) async {
    final result = await _run(['get', key]);
    if (result.exitCode != 0) return null;
    final value = result.stdout as String;
    // ksud prints the value and a newline.
    return value.endsWith('\n') ? value.substring(0, value.length - 1) : value;
  }

  @override
  Future<void> setTemp(String key, String value) async {
    // Through stdin: the value never shows in a process list.
    final result = await _run(['set', '--temp', '--stdin', key], stdin: value);
    if (result.exitCode != 0) {
      throw ProcessException(
        ksud,
        ['module', 'config', 'set', key],
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }

  @override
  Future<void> deleteTemp(String key) async {
    await _run(['delete', '--temp', key]);
  }
}

/// Where the channel's session lives: one JSON value in tmp.config.
final class SessionStore {
  SessionStore(this.config);

  final ModuleConfig config;

  Future<SessionInfo?> read() async {
    final text = await config.get(sessionConfigKey);
    if (text == null) return null;
    try {
      return SessionInfo.fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  Future<void> write(SessionInfo info) =>
      config.setTemp(sessionConfigKey, jsonEncode(info.toJson()));

  /// Removes the session if it still names [ifPid].
  Future<void> delete({required int ifPid}) async {
    if ((await read())?.pid != ifPid) return;
    await config.deleteTemp(sessionConfigKey);
  }
}

/// Takes an exclusive lock on [file], trying again every 50 ms until [wait]
/// has passed. Polls rather than blocking: a blocking lock cannot be given
/// up, and closing the file while it waits fails.
Future<bool> _tryLock(RandomAccessFile file, Duration wait) async {
  final deadline = DateTime.now().add(wait);
  while (true) {
    try {
      await file.lock(FileLock.exclusive);
      return true;
    } on FileSystemException {
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
