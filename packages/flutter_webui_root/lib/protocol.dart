// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// Wire format of the root channel, shared by the channel and its page client.
///
/// Pure Dart (no `dart:io`, no `dart:js_interop`), so both sides import it.
/// The contract is `docs/root-channel.md`.
library;

import 'dart:typed_data';

/// Protocol version. Bumped only for incompatible changes.
const int protocolVersion = 1;

/// Version of the channel executable, compared by the page on connect.
const String channelVersion = '0.2.2';

/// The WebSocket path, relative to `ws://127.0.0.1:<port>`.
const String channelPath = '/v1';

/// The only page origin every manager serves module WebUIs from.
const String managerOrigin = 'https://mui.kernelsu.org';

/// The tmp.config key (`ksud module config`) that holds the running
/// channel's [SessionInfo] as JSON. Read and written by the launcher and the
/// channel only; the page gets the session from the launcher's output.
const String sessionConfigKey = 'webui.session';

/// The tmp.config key that holds the boot id of the boot in which the
/// launcher last cleared the module's temporary directory.
const String bootConfigKey = 'webui.boot';

/// Largest file the `read` op returns.
const int maxReadBytes = 64 * 1024;

/// Largest text frame (a JSON request), in UTF-8 bytes. Larger ones are
/// answered with [ErrorCode.requestTooLarge] and otherwise ignored.
const int maxRequestBytes = 512 * 1024;

/// Largest `argv` plus `env` of one `start`, counted as UTF-8 bytes of every
/// argument and every `KEY=value` (below the kernel's `ARG_MAX`).
const int maxArgvEnvBytes = 128 * 1024;

/// Most processes one connection may have running (attached and detached).
const int maxProcessesPerConnection = 64;

/// Most processes the channel tracks over all connections.
const int maxProcesses = 256;

/// Most open connections; a further upgrade is answered with HTTP 503.
const int maxConnections = 16;

/// Most stdin bytes the channel holds for one attached process that does not
/// read them (a frame that arrives while none are held is taken whole). Past
/// it the channel answers [ErrorCode.stdinOverflow], drops the frame and
/// closes that process's stdin once the held bytes are written.
const int maxStdinBufferBytes = 1024 * 1024;

/// Stream tags in binary frames.
abstract final class StreamTag {
  static const int stdin = 0;
  static const int stdout = 1;
  static const int stderr = 2;
}

/// Signals the `signal` op accepts.
const List<String> signalNames = [
  'TERM',
  'KILL',
  'INT',
  'HUP',
  'USR1',
  'USR2',
  'STOP',
  'CONT',
];

/// A binary frame: stream bytes for one process.
final class DataFrame {
  DataFrame(this.stream, this.id, this.payload);

  final int stream;
  final int id;
  final Uint8List payload;

  static const int headerLength = 5;

  Uint8List encode() {
    final out = Uint8List(headerLength + payload.length);
    out[0] = stream;
    ByteData.sublistView(out).setUint32(1, id);
    out.setRange(headerLength, out.length, payload);
    return out;
  }

  /// Decodes a binary frame, or returns null if it is malformed.
  static DataFrame? decode(List<int> frame) {
    if (frame.length <= headerLength) return null;
    final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
    final stream = bytes[0];
    if (stream > StreamTag.stderr) return null;
    final id = ByteData.sublistView(bytes).getUint32(1);
    return DataFrame(stream, id, Uint8List.sublistView(bytes, headerLength));
  }
}

/// Where to reach the running channel: the one line `root start` prints,
/// also kept in tmp.config ([sessionConfigKey]).
final class SessionInfo {
  const SessionInfo({
    required this.protocol,
    required this.version,
    required this.port,
    required this.token,
    required this.pid,
    required this.boot,
    required this.started,
  });

  final int protocol;
  final String version;
  final int port;
  final String token;
  final int pid;
  final String boot;
  final DateTime started;

  Uri get uri => Uri(
    scheme: 'ws',
    host: '127.0.0.1',
    port: port,
    path: channelPath,
    queryParameters: {'token': token},
  );

  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'version': version,
    'port': port,
    'token': token,
    'pid': pid,
    'boot': boot,
    'started': started.toUtc().toIso8601String(),
  };

  /// Parses a decoded session, or returns null if a field is missing.
  static SessionInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final protocol = json['protocol'];
    final version = json['version'];
    final port = json['port'];
    final token = json['token'];
    final pid = json['pid'];
    final boot = json['boot'];
    final started = DateTime.tryParse('${json['started']}');
    if (protocol is! int ||
        version is! String ||
        port is! int ||
        token is! String ||
        pid is! int ||
        boot is! String ||
        started == null) {
      return null;
    }
    return SessionInfo(
      protocol: protocol,
      version: version,
      port: port,
      token: token,
      pid: pid,
      boot: boot,
      started: started,
    );
  }
}

/// Error codes in `{"op":"error"}` answers.
abstract final class ErrorCode {
  static const String badRequest = 'bad-request';
  static const String duplicateId = 'duplicate-id';
  static const String noSuchProcess = 'no-such-process';
  static const String notFound = 'not-found';
  static const String startFailed = 'start-failed';
  static const String tooLarge = 'too-large';

  /// A text frame over [maxRequestBytes], or a `start` whose `argv` and `env`
  /// are over [maxArgvEnvBytes].
  static const String requestTooLarge = 'request-too-large';

  /// A `start` past [maxProcessesPerConnection] or [maxProcesses].
  static const String tooManyProcesses = 'too-many-processes';

  /// Stdin for a process that is not reading it went past
  /// [maxStdinBufferBytes]; its stdin is closed.
  static const String stdinOverflow = 'stdin-overflow';
}
