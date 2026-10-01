// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:convert';
import 'dart:io';

import '../protocol.dart';

/// File modes of what the channel keeps in `webroot/.run/` (octal strings, as
/// `chmod` takes them). See "Files in the module" in `docs/root-channel.md`.
abstract final class RunModes {
  /// `.run/`: traversable so the manager can serve `session.json` by name,
  /// not listable.
  static const String runDir = '711';

  /// `session.json`: readable by whoever serves `webroot/` (see the doc).
  static const String session = '644';

  /// `.run/proc/`, root-only.
  static const String procDir = '700';

  /// `lock`, `root.log`, detached-process logs and exit files: root-only.
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

/// Creates `webroot/.run/` (and `.run/proc/`) and sets their modes.
Future<void> prepareRunDir(Directory webroot) async {
  final runDir = Directory('${webroot.path}/.run');
  final procDir = Directory('${runDir.path}/proc');
  await procDir.create(recursive: true);
  await setMode(runDir.path, RunModes.runDir);
  await setMode(procDir.path, RunModes.procDir);
}

/// `webroot/.run/session.json`, written by atomic rename.
final class SessionFile {
  SessionFile(Directory webroot)
    : runDir = Directory('${webroot.path}/.run'),
      file = File('${webroot.path}/$sessionFilePath');

  final Directory runDir;
  final File file;

  /// Writes [info] to a temporary file whose mode is set before the token goes
  /// in, then renames it over `session.json`.
  Future<void> write(SessionInfo info) async {
    await runDir.create(recursive: true);
    final tmp = File('${file.path}.$pid.tmp');
    try {
      await tmp.delete();
    } on FileSystemException {
      // None left over.
    }
    await tmp.create(exclusive: true);
    await setMode(tmp.path, RunModes.session);
    await tmp.writeAsString(jsonEncode(info.toJson()), flush: true);
    await tmp.rename(file.path);
  }

  SessionInfo? read() {
    try {
      return SessionInfo.fromJson(jsonDecode(file.readAsStringSync()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Removes `session.json` whatever it names, and temporary files a killed
  /// channel left behind.
  Future<void> clear() async {
    try {
      await file.delete();
    } on FileSystemException {
      // Not there.
    }
    final name = file.uri.pathSegments.last;
    try {
      await for (final f in runDir.list()) {
        final base = f.uri.pathSegments.last;
        if (f is File && base.startsWith('$name.') && base.endsWith('.tmp')) {
          try {
            await f.delete();
          } on FileSystemException {
            // Raced with its owner.
          }
        }
      }
    } on FileSystemException {
      // No run directory yet.
    }
  }

  /// Removes the file if it still names [ifPid].
  Future<void> delete({required int ifPid}) async {
    if (read()?.pid != ifPid) return;
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// Why [info], found in `session.json` when a channel starts, is stale: its
/// process is gone, it is from another boot or another channel version. Null
/// if it looks live.
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

/// Holds `.run/lock` so a second channel in the same webroot exits at once.
final class InstanceLock {
  InstanceLock._(this._file);

  final RandomAccessFile _file;

  /// Returns null if another channel holds the lock.
  static Future<InstanceLock?> acquire(Directory webroot) async {
    await prepareRunDir(webroot);
    final path = '${webroot.path}/.run/lock';
    final file = await File(path).open(mode: FileMode.append);
    try {
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      await file.close();
      return null;
    }
    await setMode(path, RunModes.private);
    return InstanceLock._(file);
  }

  Future<void> release() async {
    await _file.unlock();
    await _file.close();
  }
}
