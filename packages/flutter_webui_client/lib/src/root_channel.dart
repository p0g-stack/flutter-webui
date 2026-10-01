// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webui_root/protocol.dart';

import 'bridge.dart';
import 'quote.dart';

/// Opens the socket for [RootChannel]. The web implementation uses the
/// browser `WebSocket`; tests use `dart:io`.
abstract interface class ChannelTransport {
  /// Opens the WebSocket.
  Future<ChannelSocket> connect(Uri uri);
}

/// One open WebSocket.
abstract interface class ChannelSocket {
  /// Text frames as [String], binary frames as [Uint8List].
  Stream<Object> get frames;
  void sendText(String text);
  void sendBytes(Uint8List bytes);
  Future<void> close();
}

/// Runs `root start` through the bridge (see [channelStartCommand]): it finds
/// or starts the channel and prints its session as one JSON line.
typedef ChannelStarter = Future<ExecResult> Function();

/// The command line that finds or starts the channel for [moduleDir].
String channelStartCommand(String moduleDir) =>
    shellCommand(['sh', '$moduleDir/flutter_webui/root', 'start']);

/// A failed request, with the channel's error code
/// (`bad-request`, `not-found`, `start-failed`, ...).
final class RootChannelException implements Exception {
  const RootChannelException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'RootChannelException($code): $message';
}

/// The page side of the root channel (`docs/root-channel.md`).
final class RootChannel {
  RootChannel._(this._socket, this.session, Map<String, Object?> hello)
    : moduleDir = hello['moduleDir'] as String?,
      uid = hello['uid'] as int? {
    _subscription = _socket.frames.listen(
      _onFrame,
      onDone: _onClosed,
      onError: (Object _) => _onClosed(),
    );
  }

  /// Finds or starts the channel and connects.
  ///
  /// Runs [start] (`root start`), which prints the session of a live channel
  /// of this version, starting one if needed, and connects to it. Tries once
  /// more if the channel it named went away before the connection (it was
  /// exiting while idle).
  static Future<RootChannel> connect({
    required ChannelTransport transport,
    required ChannelStarter start,
    int attempts = 2,
  }) async {
    var problem = 'not tried';
    for (var i = 0; i < attempts; i++) {
      final result = await start();
      final info = parseSession(result.stdout);
      if (result.exitCode != 0 || info == null) {
        final err = result.stderr.trim();
        problem =
            'root start exited ${result.exitCode}'
            '${err.isEmpty ? '' : ': $err'}';
        continue;
      }
      final channel = await _tryOpen(transport, info);
      if (channel != null) return channel;
      problem =
          'the channel at port ${info.port} did not accept the connection';
    }
    throw RootChannelException('unavailable', problem);
  }

  /// The session in `root start`'s output: its last non-empty line.
  static SessionInfo? parseSession(String stdout) {
    final lines = const LineSplitter()
        .convert(stdout)
        .where((l) => l.trim().isNotEmpty);
    if (lines.isEmpty) return null;
    try {
      return SessionInfo.fromJson(jsonDecode(lines.last));
    } on FormatException {
      return null;
    }
  }

  static Future<RootChannel?> _tryOpen(
    ChannelTransport transport,
    SessionInfo info,
  ) async {
    final ChannelSocket socket;
    try {
      socket = await transport.connect(info.uri);
    } on Object {
      return null;
    }
    final frames = StreamIterator(socket.frames);
    // The hello must come first; re-wrap the remaining frames.
    final Object first;
    try {
      if (!await frames.moveNext().timeout(const Duration(seconds: 2))) {
        return null;
      }
      first = frames.current;
    } on Object {
      await socket.close();
      return null;
    }
    final hello = first is String ? jsonDecode(first) : null;
    if (hello is! Map<String, Object?> || hello['op'] != 'hello') {
      await socket.close();
      return null;
    }
    return RootChannel._(_RestSocket(socket, frames), info, hello);
  }

  final ChannelSocket _socket;
  late final StreamSubscription<Object> _subscription;

  /// The session this connection came from.
  final SessionInfo session;

  /// The module directory, as the channel reports it.
  final String? moduleDir;

  /// The channel's uid (0 when it runs as root).
  final int? uid;

  int _nextId = 1;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  final Map<int, RootProcess> _processes = {};
  final Completer<void> _closed = Completer<void>();

  /// Completes when the connection is gone.
  Future<void> get closed => _closed.future;

  bool get isClosed => _closed.isCompleted;

  /// Starts [argv] as root. See `docs/root-channel.md` for attached and
  /// [detached] processes.
  Future<RootProcess> start(
    List<String> argv, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool detached = false,
  }) async {
    final id = _nextId++;
    final process = RootProcess._(this, id, detached);
    _processes[id] = process;
    try {
      final started = await _request(id, {
        'op': 'start',
        'argv': argv,
        'cwd': ?workingDirectory,
        'env': ?environment,
        if (detached) 'detached': true,
      });
      process._pid = started['pid'] as int;
      return process;
    } on Object {
      _processes.remove(id);
      rethrow;
    }
  }

  /// Reads a small UTF-8 file inside the module directory.
  Future<String> read(String path) async {
    final answer = await _request(_nextId++, {'op': 'read', 'path': path});
    return answer['data'] as String;
  }

  /// Asks the channel to end its attached processes and exit.
  Future<void> shutdown() async {
    _send({'op': 'shutdown', 'id': _nextId++});
    await close();
  }

  /// Closes this connection. Attached processes end; detached ones go on.
  Future<void> close() async {
    await _socket.close();
    _onClosed();
  }

  Future<Map<String, Object?>> _request(int id, Map<String, Object?> body) {
    if (isClosed) {
      return Future.error(
        const RootChannelException(
          'closed',
          'the channel connection is closed',
        ),
      );
    }
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _send({...body, 'id': id});
    return completer.future;
  }

  void _send(Map<String, Object?> message) {
    if (!isClosed) _socket.sendText(jsonEncode(message));
  }

  void _onFrame(Object frame) {
    if (frame is Uint8List) {
      final data = DataFrame.decode(frame);
      if (data != null) _processes[data.id]?._output(data.stream, data.payload);
      return;
    }
    final message = jsonDecode(frame as String) as Map<String, Object?>;
    final id = message['id'];
    switch (message['op']) {
      case 'error':
        final error = RootChannelException(
          '${message['code']}',
          '${message['message']}',
        );
        final pending = _pending.remove(id);
        if (pending != null) {
          pending.completeError(error);
        } else {
          _processes[id]?._fail(error);
        }
      case 'exit':
        _processes.remove(id)?._exit(message['code'] as int);
      default:
        _pending.remove(id)?.complete(message);
    }
  }

  void _onClosed() {
    if (_closed.isCompleted) return;
    _closed.complete();
    unawaited(_subscription.cancel());
    const error = RootChannelException(
      'closed',
      'the channel connection closed',
    );
    for (final p in _pending.values) {
      p.completeError(error);
    }
    _pending.clear();
    for (final p in _processes.values) {
      p._fail(error);
    }
    _processes.clear();
  }
}

/// A process the root channel started.
final class RootProcess {
  RootProcess._(this._channel, this.id, this.detached) {
    _exitCode.future.ignore();
    _stdin.stream.listen(
      (bytes) => _channel._socket.sendBytes(
        DataFrame(StreamTag.stdin, id, Uint8List.fromList(bytes)).encode(),
      ),
      onDone: () => _channel._send({'op': 'close-stdin', 'id': id}),
    );
  }

  final RootChannel _channel;

  /// This process's id on the connection.
  final int id;

  /// Whether it runs detached (outlives the page and the channel).
  final bool detached;

  int? _pid;

  /// The process id (for a detached process, its wrapper shell's).
  int get pid => _pid!;

  final StreamController<List<int>> _stdout = StreamController();
  final StreamController<List<int>> _stderr = StreamController();
  final StreamController<List<int>> _stdin = StreamController();
  final Completer<int> _exitCode = Completer<int>();

  /// Standard output; for a detached process, its log (stdout and stderr).
  Stream<List<int>> get stdout => _stdout.stream;

  Stream<List<int>> get stderr => _stderr.stream;

  /// Standard input; closing it sends `close-stdin`. Ignored when detached.
  StreamSink<List<int>> get stdin => _stdin.sink;

  /// The exit code: minus the signal number for an attached process ended by
  /// a signal, `128 + n` for a detached one. Fails if the connection closes
  /// first.
  Future<int> get exitCode => _exitCode.future;

  /// stdout decoded as UTF-8 lines.
  Stream<String> get lines =>
      stdout.transform(utf8.decoder).transform(const LineSplitter());

  /// Sends [signal] (`TERM`, `KILL`, `INT`, `HUP`, `USR1`, `USR2`, `STOP`,
  /// `CONT`).
  void kill([String signal = 'TERM']) =>
      _channel._send({'op': 'signal', 'id': id, 'signal': signal});

  void _output(int stream, List<int> bytes) {
    (stream == StreamTag.stderr ? _stderr : _stdout).add(bytes);
  }

  void _exit(int code) {
    _stdout.close();
    _stderr.close();
    if (!_exitCode.isCompleted) _exitCode.complete(code);
  }

  void _fail(Object error) {
    _stdout.close();
    _stderr.close();
    if (!_exitCode.isCompleted) _exitCode.completeError(error);
  }
}

/// A socket whose first frame was already consumed by [RootChannel._tryOpen].
final class _RestSocket implements ChannelSocket {
  _RestSocket(this._socket, this._iterator);

  final ChannelSocket _socket;
  final StreamIterator<Object> _iterator;

  @override
  late final Stream<Object> frames = () {
    final controller = StreamController<Object>(sync: true);
    controller.onListen = () async {
      while (await _iterator.moveNext()) {
        controller.add(_iterator.current);
      }
      await controller.close();
    };
    controller.onCancel = _iterator.cancel;
    return controller.stream;
  }();

  @override
  void sendText(String text) => _socket.sendText(text);

  @override
  void sendBytes(Uint8List bytes) => _socket.sendBytes(bytes);

  @override
  Future<void> close() => _socket.close();
}
