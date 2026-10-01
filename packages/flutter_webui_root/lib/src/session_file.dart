// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:convert';
import 'dart:io';

import '../protocol.dart';

/// `webroot/.run/session.json`, written by atomic rename.
final class SessionFile {
  SessionFile(Directory webroot)
    : runDir = Directory('${webroot.path}/.run'),
      file = File('${webroot.path}/$sessionFilePath');

  final Directory runDir;
  final File file;

  Future<void> write(SessionInfo info) async {
    await runDir.create(recursive: true);
    final tmp = File('${file.path}.$pid.tmp');
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
    final runDir = Directory('${webroot.path}/.run');
    await runDir.create(recursive: true);
    final file = await File('${runDir.path}/lock').open(mode: FileMode.append);
    try {
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      await file.close();
      return null;
    }
    return InstanceLock._(file);
  }

  Future<void> release() async {
    await _file.unlock();
    await _file.close();
  }
}
