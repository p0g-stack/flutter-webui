// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:io';

/// The root cgroups that [leaveAppCgroup] moves a process into, relative to
/// the file system root: the cgroup v2 root (Android 12 and later freeze an
/// app's `uid_<uid>/pid_<pid>` group under it) and the cgroup v1 freezer root
/// (Android 11).
const List<String> rootCgroupProcs = [
  'sys/fs/cgroup/cgroup.procs',
  'dev/freezer/cgroup.procs',
];

/// Moves process [pid] into the root cgroups, out of the cgroup of the
/// manager app that started it.
///
/// The manager runs `root start` from its own process, so the channel is
/// born in the manager's cgroup; when Android caches the manager it freezes
/// that cgroup, and with it the channel and every process the channel
/// starts (they inherit the cgroup). Returns one line per hierarchy for
/// root.log: `/proc/<pid>/cgroup` before and after, or why the move failed.
/// Never throws.
List<String> leaveAppCgroup(int pid, {String fsRoot = '/'}) {
  String cgroups() {
    try {
      return File('$fsRoot/proc/$pid/cgroup')
          .readAsStringSync()
          .trim()
          .replaceAll('\n', ' ');
    } on FileSystemException {
      return '?';
    }
  }

  final lines = <String>['cgroup before: ${cgroups()}'];
  for (final rel in rootCgroupProcs) {
    final procs = File('$fsRoot/$rel');
    if (FileSystemEntity.typeSync(procs.path) ==
        FileSystemEntityType.notFound) {
      continue;
    }
    try {
      procs.writeAsStringSync('$pid\n', flush: true);
    } on FileSystemException catch (e) {
      lines.add('cgroup: moving to /$rel: ${e.osError?.message ?? e.message}');
    }
  }
  lines.add('cgroup after: ${cgroups()}');
  return lines;
}
