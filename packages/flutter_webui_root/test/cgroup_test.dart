// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:io';

import 'package:flutter_webui_root/flutter_webui_root.dart';
import 'package:test/test.dart';

void main() {
  late Directory fs;

  setUp(() async {
    fs = await Directory.systemTemp.createTemp('fs');
    File('${fs.path}/proc/42/cgroup')
      ..createSync(recursive: true)
      ..writeAsStringSync('0::/uid_10209/pid_11034\n');
  });

  tearDown(() => fs.delete(recursive: true));

  test('writes the pid to every root cgroup present and logs', () {
    final v2 = File('${fs.path}/sys/fs/cgroup/cgroup.procs')
      ..createSync(recursive: true);
    final v1 = File('${fs.path}/dev/freezer/cgroup.procs')
      ..createSync(recursive: true);
    final lines = leaveAppCgroup(42, fsRoot: fs.path);
    expect(v2.readAsStringSync(), '42\n');
    expect(v1.readAsStringSync(), '42\n');
    expect(lines, [
      'cgroup before: 0::/uid_10209/pid_11034',
      'cgroup after: 0::/uid_10209/pid_11034',
    ]);
  });

  test('skips missing hierarchies and reports a failed move', () {
    Directory('${fs.path}/sys/fs/cgroup/cgroup.procs')
        .createSync(recursive: true);
    final lines = leaveAppCgroup(42, fsRoot: fs.path);
    expect(lines, hasLength(3));
    expect(
      lines[1],
      startsWith('cgroup: moving to /sys/fs/cgroup/cgroup.procs'),
    );
  });

  test('never throws without /proc', () {
    expect(leaveAppCgroup(7, fsRoot: fs.path), [
      'cgroup before: ?',
      'cgroup after: ?',
    ]);
  });
}
