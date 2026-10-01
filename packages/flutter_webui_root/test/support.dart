// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webui_root/flutter_webui_root.dart';
import 'package:test/test.dart';

/// A bare protocol client for tests.
class Client {
  Client._(this.socket) {
    socket.listen(
      (frame) {
        if (frame is String) {
          _messages.add(jsonDecode(frame) as Map<String, Object?>);
        } else {
          _data.add(DataFrame.decode(frame as List<int>)!);
        }
      },
      onDone: () {
        _messages.close();
        _data.close();
      },
    );
  }

  static Future<Client> connect(
    SessionInfo info, {
    String? origin = managerOrigin,
  }) async {
    final socket = await WebSocket.connect(
      info.uri.toString(),
      headers: {'origin': ?origin},
    );
    return Client._(socket);
  }

  final WebSocket socket;
  final _messages = StreamController<Map<String, Object?>>();
  final _data = StreamController<DataFrame>.broadcast(sync: true);
  late final messages = StreamIterator(_messages.stream);
  Stream<DataFrame> get data => _data.stream;

  void send(Map<String, Object?> m) => socket.add(jsonEncode(m));
  void stdin(int id, String text) => socket.add(
    DataFrame(
      StreamTag.stdin,
      id,
      Uint8List.fromList(utf8.encode(text)),
    ).encode(),
  );

  Future<Map<String, Object?>> next() async {
    if (!await messages.moveNext().timeout(const Duration(seconds: 10))) {
      throw StateError('closed');
    }
    return messages.current;
  }

  Future<Map<String, Object?>> nextOp(String op) async {
    while (true) {
      final m = await next();
      if (m['op'] == op) return m;
    }
  }

  Future<void> close() => socket.close();
}

Future<void> waitGone(int pid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final stat = File('/proc/$pid/stat');
    if (!stat.existsSync() || stat.readAsStringSync().split(' ')[2] == 'Z') {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('process $pid still running');
}

/// The permission bits of [path], as an octal string such as `644`.
String modeOf(String path) =>
    (FileStat.statSync(path).mode & 0x1ff).toRadixString(8);

/// tmp.config in memory, in place of `ksud module config`.
class MemoryConfig implements ModuleConfig {
  final Map<String, String> temp = {};

  @override
  Future<String?> get(String key) async => temp[key];

  @override
  Future<void> setTemp(String key, String value) async => temp[key] = value;

  @override
  Future<void> deleteTemp(String key) async => temp.remove(key);
}
