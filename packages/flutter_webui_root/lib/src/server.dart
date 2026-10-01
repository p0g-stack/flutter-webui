// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../protocol.dart';
import 'run_state.dart';

/// Timings, overridable for tests.
final class ChannelTimings {
  const ChannelTimings({
    this.ping = const Duration(seconds: 15),
    this.idleExit = const Duration(seconds: 30),
    this.killAfterTerm = const Duration(seconds: 3),
    this.tailPoll = const Duration(milliseconds: 50),
  });

  final Duration ping;
  final Duration idleExit;
  final Duration killAfterTerm;
  final Duration tailPoll;
}

/// Caps on what connections may ask for, overridable for tests. The defaults
/// are the constants in `protocol.dart`.
final class ChannelLimits {
  const ChannelLimits({
    this.connections = maxConnections,
    this.processes = maxProcesses,
    this.processesPerConnection = maxProcessesPerConnection,
    this.requestBytes = maxRequestBytes,
    this.argvEnvBytes = maxArgvEnvBytes,
    this.stdinBufferBytes = maxStdinBufferBytes,
  });

  final int connections;
  final int processes;
  final int processesPerConnection;
  final int requestBytes;
  final int argvEnvBytes;
  final int stdinBufferBytes;
}

/// The root channel: one WebSocket server on 127.0.0.1 and the processes its
/// connections started. See `docs/root-channel.md`.
final class RootChannelServer {
  RootChannelServer._(
    this._http,
    this._store,
    this._token,
    this.moduleDir,
    this.runDir,
    this.timings,
    this.limits,
    this.log,
  );

  /// Binds 127.0.0.1 on a free port and writes the session to [store].
  ///
  /// The launcher starts the channel while it holds `start.lock` in
  /// [runDir], and replaces whatever session the store held.
  static Future<RootChannelServer> start({
    required Directory moduleDir,
    required Directory runDir,
    required SessionStore store,
    ChannelTimings timings = const ChannelTimings(),
    ChannelLimits limits = const ChannelLimits(),
    void Function(String) log = _noLog,
  }) async {
    final procDir = Directory('${runDir.path}/proc');
    await prepareRunDir(runDir);
    final boot = readBootId();
    _clearOtherBoots(procDir, boot, log);
    _pruneLogs(procDir);
    final token = _newToken();
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final info = SessionInfo(
      protocol: protocolVersion,
      version: channelVersion,
      port: http.port,
      token: token,
      pid: pid,
      boot: boot,
      started: DateTime.now(),
    );
    final server = RootChannelServer._(
      http,
      store,
      token,
      moduleDir.absolute,
      runDir,
      timings,
      limits,
      log,
    );
    http.listen(server._handleRequest, onError: (Object e) => log('http: $e'));
    await store.write(info);
    server.info = info;
    server._checkIdle();
    log('listening on 127.0.0.1:${http.port}');
    return server;
  }

  final HttpServer _http;
  final SessionStore _store;
  final String _token;
  final Directory moduleDir;
  final Directory runDir;
  final ChannelTimings timings;
  final ChannelLimits limits;
  final void Function(String) log;

  late final SessionInfo info;

  final Set<_Connection> _connections = {};
  final Set<_Child> _children = {};
  final Completer<void> _done = Completer<void>();
  Timer? _idleTimer;
  bool _closing = false;
  int _detachedCount = 0;
  int _upgrading = 0;
  int _starting = 0;

  /// Completes when the channel has shut down.
  Future<void> get done => _done.future;

  int get port => _http.port;

  /// Ends attached processes, withdraws the session and stops listening.
  /// Detached processes keep running.
  Future<void> shutdown() async {
    if (_closing) return done;
    _closing = true;
    _idleTimer?.cancel();
    log('shutting down');
    await Future.wait([for (final c in _children.toList()) c.release()]);
    for (final c in _connections.toList()) {
      await c.socket.close(WebSocketStatus.goingAway);
    }
    await _withdrawSession();
    await _http.close(force: true);
    if (!_done.isCompleted) _done.complete();
  }

  /// Removes the session from the store if it still names this channel. No
  /// lock needed: the next channel writes its session only after this one
  /// releases `lock`, which it does after this.
  Future<void> _withdrawSession() async {
    try {
      await _store.delete(ifPid: pid);
    } on Object catch (e) {
      log('withdrawing the session: $e');
    }
  }

  /// Never throws: an error here would end the channel, and any local app
  /// can send a request.
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      await _accept(request);
    } on Object catch (e) {
      log('request: $e');
      try {
        await request.response.close();
      } on Object {
        // The peer is gone.
      }
    }
  }

  Future<void> _accept(HttpRequest request) async {
    final List<String> origins;
    final String? token;
    try {
      origins = request.headers['origin'] ?? const [];
      token = request.uri.queryParameters['token'];
    } on FormatException {
      return _reject(request, HttpStatus.badRequest);
    }
    if (request.uri.path != channelPath) {
      return _reject(request, HttpStatus.notFound);
    }
    if (token == null || !_sameToken(token, _token)) {
      return _reject(request, HttpStatus.unauthorized);
    }
    if (origins.length > 1 ||
        (origins.isNotEmpty && origins.single != managerOrigin)) {
      return _reject(request, HttpStatus.forbidden);
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      return _reject(request, HttpStatus.upgradeRequired);
    }
    if (_closing || _connections.length + _upgrading >= limits.connections) {
      return _reject(request, HttpStatus.serviceUnavailable);
    }
    final WebSocket socket;
    _upgrading++;
    try {
      // No permessage-deflate: nothing to gain on loopback, and an inflated
      // frame could be far larger than what was sent.
      socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionOff,
      );
    } finally {
      _upgrading--;
    }
    if (_closing) {
      await socket.close(WebSocketStatus.goingAway);
      return;
    }
    socket.pingInterval = timings.ping;
    final connection = _Connection(this, socket);
    _connections.add(connection);
    _checkIdle();
    connection.send({
      'op': 'hello',
      'protocol': protocolVersion,
      'version': channelVersion,
      'pid': pid,
      'boot': info.boot,
      'uid': _uid(),
      'moduleDir': moduleDir.path,
    });
    socket.listen(
      connection.onFrame,
      onDone: () => _onConnectionClosed(connection),
      onError: (Object _) => _onConnectionClosed(connection),
      cancelOnError: true,
    );
  }

  Future<void> _reject(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }

  void _onConnectionClosed(_Connection connection) {
    if (!_connections.remove(connection)) return;
    for (final child in connection.byId.values.toList()) {
      unawaited(child.release());
    }
    _checkIdle();
  }

  void _checkIdle() {
    _idleTimer?.cancel();
    if (_closing || _connections.isNotEmpty || _children.isNotEmpty) return;
    _idleTimer = Timer(timings.idleExit, shutdown);
  }

  bool _isOpen(_Connection connection) =>
      !_closing && _connections.contains(connection);

  void _removeChild(_Child child) {
    _children.remove(child);
    _checkIdle();
  }

  /// Resolves [path] and returns it if it lies inside the module directory.
  String? _insideModule(String path) {
    if (!path.startsWith('/')) return null;
    final String resolved;
    try {
      resolved = File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
    final root = moduleDir.resolveSymbolicLinksSync();
    return resolved.startsWith('$root/') ? resolved : null;
  }
}

/// One page connection and the ids it uses for processes.
final class _Connection {
  _Connection(this.server, this.socket);

  final RootChannelServer server;
  final WebSocket socket;
  final Map<int, _Child> byId = {};

  /// Ids of `start` requests still launching.
  final Set<int> _starting = {};

  void send(Map<String, Object?> message) {
    if (socket.readyState == WebSocket.open) socket.add(jsonEncode(message));
  }

  void sendData(int stream, int id, List<int> bytes) {
    if (socket.readyState != WebSocket.open || bytes.isEmpty) return;
    final payload = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    socket.add(DataFrame(stream, id, payload).encode());
  }

  void error(Object? id, String code, String message) =>
      send({'op': 'error', 'id': id, 'code': code, 'message': message});

  /// Never throws: an error here would end the channel.
  void onFrame(dynamic frame) {
    try {
      _onFrame(frame);
    } on Object catch (e, s) {
      server.log('frame: $e\n$s');
      error(null, ErrorCode.badRequest, 'request failed');
    }
  }

  void _onFrame(dynamic frame) {
    if (frame is List<int>) return _onData(frame);
    final text = frame as String;
    final cap = server.limits.requestBytes;
    if (text.length > cap ||
        (text.length * 3 > cap && utf8.encode(text).length > cap)) {
      return error(
        null,
        ErrorCode.requestTooLarge,
        'requests are at most $cap bytes',
      );
    }
    Object? message;
    try {
      message = jsonDecode(text);
    } on FormatException {
      return error(null, ErrorCode.badRequest, 'not JSON');
    }
    if (message is! Map) {
      return error(null, ErrorCode.badRequest, 'not an object');
    }
    final id = message['id'];
    if (id is! int || id <= 0 || id > 0xffffffff) {
      return error(id, ErrorCode.badRequest, 'id must be a positive uint32');
    }
    switch (message['op']) {
      case 'start':
        unawaited(
          _start(id, message).catchError((Object e) {
            server.log('start $id: $e');
            error(id, ErrorCode.startFailed, '$e');
          }),
        );
      case 'close-stdin':
        _withChild(id, (c) => c.closeStdin());
      case 'signal':
        final name = message['signal'];
        final signal = name is String ? _signals[name] : null;
        if (signal == null) {
          return error(id, ErrorCode.badRequest, 'unknown signal $name');
        }
        _withChild(id, (c) => c.signal(signal));
      case 'read':
        _read(id, message['path']);
      case 'shutdown':
        unawaited(server.shutdown());
      default:
        error(id, ErrorCode.badRequest, 'unknown op ${message['op']}');
    }
  }

  void _withChild(int id, void Function(_Child) action) {
    final child = byId[id];
    if (child == null) {
      return error(id, ErrorCode.noSuchProcess, 'no process $id');
    }
    action(child);
  }

  void _onData(List<int> frame) {
    final data = DataFrame.decode(frame);
    if (data == null || data.stream != StreamTag.stdin) {
      return error(null, ErrorCode.badRequest, 'bad data frame');
    }
    byId[data.id]?.writeStdin(data.payload);
  }

  Future<void> _start(int id, Map<dynamic, dynamic> m) async {
    if (byId.containsKey(id) || _starting.contains(id)) {
      return error(id, ErrorCode.duplicateId, 'id $id is in use');
    }
    final argv = m['argv'];
    final cwd = m['cwd'];
    final env = m['env'];
    final detached = m['detached'] ?? false;
    if (argv is! List ||
        argv.isEmpty ||
        argv.any((a) => a is! String || a.contains('\x00')) ||
        (argv.first as String).isEmpty ||
        (cwd != null &&
            (cwd is! String || !cwd.startsWith('/') || cwd.contains('\x00'))) ||
        (env != null &&
            (env is! Map ||
                env.entries.any(
                  (e) =>
                      e.key is! String ||
                      e.value is! String ||
                      !_validEnvName(e.key as String) ||
                      (e.value as String).contains('\x00'),
                ))) ||
        detached is! bool) {
      return error(id, ErrorCode.badRequest, 'bad start request');
    }
    final args = argv.cast<String>();
    final environment = (env as Map?)?.cast<String, String>();
    var size = 0;
    for (final a in args) {
      size += utf8.encode(a).length + 1;
    }
    environment?.forEach((k, v) => size += utf8.encode('$k=$v').length + 1);
    if (size > server.limits.argvEnvBytes) {
      return error(
        id,
        ErrorCode.requestTooLarge,
        'argv and env are over ${server.limits.argvEnvBytes} bytes',
      );
    }
    if (byId.length + _starting.length >=
        server.limits.processesPerConnection) {
      return error(
        id,
        ErrorCode.tooManyProcesses,
        'at most ${server.limits.processesPerConnection} processes per connection',
      );
    }
    if (server._children.length + server._starting >= server.limits.processes) {
      return error(
        id,
        ErrorCode.tooManyProcesses,
        'at most ${server.limits.processes} processes',
      );
    }
    if (server._closing) {
      return error(id, ErrorCode.startFailed, 'the channel is shutting down');
    }
    _starting.add(id);
    server._starting++;
    try {
      final _Child child = detached
          ? await _DetachedChild.start(
              this,
              id,
              args,
              cwd as String?,
              environment,
            )
          : await _PipedChild.start(
              this,
              id,
              args,
              cwd as String?,
              environment,
            );
      byId[id] = child;
      server._children.add(child);
      if (!server._isOpen(this)) {
        // The owner or the channel went away while it launched.
        child.run();
        await child.release();
        return;
      }
      server._checkIdle();
      send({'op': 'started', 'id': id, 'pid': child.pid});
      child.run();
    } on ProcessException catch (e) {
      error(id, ErrorCode.startFailed, e.message.isEmpty ? '$e' : e.message);
    } on FileSystemException catch (e) {
      error(id, ErrorCode.startFailed, e.message);
    } finally {
      _starting.remove(id);
      server._starting--;
    }
  }

  void _read(int id, Object? path) {
    if (path is! String) {
      return error(id, ErrorCode.badRequest, 'path required');
    }
    final resolved = server._insideModule(path);
    if (resolved == null) {
      return error(id, ErrorCode.notFound, 'no file $path in the module');
    }
    // Only regular files: opening a FIFO would block the channel.
    if (FileStat.statSync(resolved).type != FileSystemEntityType.file) {
      return error(id, ErrorCode.notFound, '$path is not a regular file');
    }
    try {
      final file = File(resolved).openSync();
      final bytes = BytesBuilder(copy: false);
      try {
        // One byte more than allowed tells a file that is too large.
        while (bytes.length <= maxReadBytes) {
          final chunk = file.readSync(maxReadBytes + 1 - bytes.length);
          if (chunk.isEmpty) break;
          bytes.add(chunk);
        }
      } finally {
        file.closeSync();
      }
      if (bytes.length > maxReadBytes) {
        return error(
          id,
          ErrorCode.tooLarge,
          '$path is over $maxReadBytes bytes',
        );
      }
      send({'op': 'read', 'id': id, 'data': utf8.decode(bytes.takeBytes())});
    } on FileSystemException catch (e) {
      error(id, ErrorCode.notFound, e.message);
    } on FormatException {
      error(id, ErrorCode.badRequest, '$path is not UTF-8');
    }
  }

  /// Sends `exit` and forgets [child]; called once per child.
  void finished(_Child child, int code) {
    send({'op': 'exit', 'id': child.id, 'code': code});
    byId.remove(child.id);
    server._removeChild(child);
  }
}

/// A process started by one connection.
sealed class _Child {
  _Child(this.owner, this.id);

  final _Connection owner;
  final int id;
  int get pid;

  void run();
  void writeStdin(List<int> bytes);
  void closeStdin();
  void signal(ProcessSignal signal);

  /// The owner is gone: end or let go of the process.
  Future<void> release();
}

/// A child with stdio pipes, ended when its owner or the channel goes.
final class _PipedChild extends _Child {
  _PipedChild._(super.owner, super.id, this.process) {
    // Stdin goes through a queue whose size is known: IOSink.add would hold
    // any amount for a child that does not read. The consumer pauses the queue
    // while the pipe is full; that is the stdin side, never stdout/stderr.
    process.stdin
        .addStream(
          _stdin.stream.map((bytes) {
            _stdinHeld -= bytes.length;
            return bytes;
          }),
        )
        .then<void>((_) => process.stdin.close())
        .catchError((Object _) {
          // The child closed its end.
          _stdinClosed = true;
        });
  }

  static Future<_PipedChild> start(
    _Connection owner,
    int id,
    List<String> argv,
    String? cwd,
    Map<String, String>? env,
  ) async {
    final process = await Process.start(
      argv.first,
      argv.sublist(1),
      workingDirectory: cwd,
      environment: env,
    );
    return _PipedChild._(owner, id, process);
  }

  final Process process;
  final StreamController<List<int>> _stdin = StreamController();
  int _stdinHeld = 0;
  bool _stdinClosed = false;
  bool _released = false;

  @override
  int get pid => process.pid;

  @override
  void run() {
    process.stdin.done.catchError((Object _) {});
    // Output is never paused: pausing a dart:io pipe stream can lose its read
    // wake-up and stall the child for good (seen on Dart 3.13.4).
    final out = process.stdout
        .listen((b) => owner.sendData(StreamTag.stdout, id, b))
        .asFuture<void>();
    final err = process.stderr
        .listen((b) => owner.sendData(StreamTag.stderr, id, b))
        .asFuture<void>();
    Future.wait([process.exitCode, out, err]).then((results) {
      if (!_released) owner.finished(this, results.first as int);
    });
  }

  @override
  void writeStdin(List<int> bytes) {
    if (_stdinClosed) return;
    final cap = owner.server.limits.stdinBufferBytes;
    // A frame is taken whole while nothing waits, whatever its size.
    if (_stdinHeld > 0 && _stdinHeld + bytes.length > cap) {
      owner.error(
        id,
        ErrorCode.stdinOverflow,
        'over $cap stdin bytes waiting; stdin closed',
      );
      return closeStdin();
    }
    _stdinHeld += bytes.length;
    _stdin.add(bytes);
  }

  @override
  void closeStdin() {
    if (_stdinClosed) return;
    _stdinClosed = true;
    unawaited(_stdin.close());
  }

  @override
  void signal(ProcessSignal signal) => process.kill(signal);

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    owner.byId.remove(id);
    closeStdin();
    process.kill(ProcessSignal.sigterm);
    final exited = await process.exitCode
        .then((_) => true)
        .timeout(owner.server.timings.killAfterTerm, onTimeout: () => false);
    if (!exited) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    owner.server._removeChild(this);
  }
}

/// A child in its own session with stdin from /dev/null and output to a log
/// file. It outlives its owner and the channel; the channel tails the log to
/// the owner and reports the exit code a wrapper shell writes.
final class _DetachedChild extends _Child {
  _DetachedChild._(super.owner, super.id, this.pid, this.log, this.exitFile);

  static Future<_DetachedChild> start(
    _Connection owner,
    int id,
    List<String> argv,
    String? cwd,
    Map<String, String>? env,
  ) async {
    final server = owner.server;
    final stem =
        '${server.runDir.path}/proc/${DateTime.now().microsecondsSinceEpoch}-${server._detachedCount++}';
    final log = File('$stem.log');
    final exitFile = File('$stem.exit');
    await log.writeAsBytes(const []);
    await setMode(log.path, RunModes.private);
    final shell = _shell();
    // The wrapper shell runs argv ("$@", never re-parsed) and records its exit
    // code (root-only, as the log). Its traps are handlers, not ignores, so the
    // child still gets the default action for signals sent to the group; the
    // umask is the subshell's only, the child keeps the channel's.
    final process = await Process.start(
      shell,
      [
        '-c',
        r'trap : TERM INT HUP USR1 USR2; exec 0</dev/null; "$@" >>"$FLUTTER_WEBUI_LOG" 2>&1; c=$?; (umask 077 && echo $c >"$FLUTTER_WEBUI_EXIT.tmp"); mv "$FLUTTER_WEBUI_EXIT.tmp" "$FLUTTER_WEBUI_EXIT"',
        'sh',
        ...argv,
      ],
      workingDirectory: cwd,
      environment: {
        ...?env,
        'FLUTTER_WEBUI_LOG': log.path,
        'FLUTTER_WEBUI_EXIT': exitFile.path,
      },
      mode: ProcessStartMode.detached,
    );
    return _DetachedChild._(owner, id, process.pid, log, exitFile);
  }

  @override
  final int pid;
  final File log;
  final File exitFile;
  RandomAccessFile? _reader;
  Timer? _timer;
  bool _released = false;

  @override
  void run() {
    _timer = Timer.periodic(owner.server.timings.tailPoll, (_) => _poll());
  }

  void _poll() {
    if (_released) return;
    try {
      final reader = _reader ??= log.openSync();
      final exited = exitFile.existsSync();
      while (true) {
        final chunk = reader.readSync(64 * 1024);
        if (chunk.isEmpty) break;
        owner.sendData(StreamTag.stdout, id, chunk);
      }
      if (!exited) return;
      final code = int.tryParse(exitFile.readAsStringSync().trim()) ?? -1;
      _stop();
      owner.finished(this, code);
    } on FileSystemException catch (e) {
      // The log or exit file went away (removed by hand): report what is
      // known rather than end the channel.
      owner.server.log('detached $pid: $e');
      _stop();
      owner.finished(this, -1);
    }
  }

  void _stop() {
    _timer?.cancel();
    _reader?.closeSync();
    _reader = null;
  }

  @override
  void writeStdin(List<int> bytes) {}

  @override
  void closeStdin() {}

  /// Signals the process group the wrapper runs in.
  @override
  void signal(ProcessSignal signal) {
    // Once the wrapper has recorded an exit its pid may be reused.
    if (exitFile.existsSync()) return;
    final group = _processGroup(pid);
    if (group == null) return;
    Process.runSync('kill', ['-${signal.name.substring(3)}', '--', '-$group']);
  }

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _stop();
    owner.byId.remove(id);
    owner.server._removeChild(this);
  }
}

String _shell() =>
    File('/system/bin/sh').existsSync() ? '/system/bin/sh' : '/bin/sh';

int? _processGroup(int pid) {
  try {
    final stat = File('/proc/$pid/stat').readAsStringSync();
    // Fields after the parenthesised command: state, ppid, pgrp, ...
    final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    return int.tryParse(rest[2]);
  } on FileSystemException {
    return null;
  }
}

/// Keeps the 16 newest detached-process logs.
void _pruneLogs(Directory dir) {
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => !f.uri.pathSegments.last.startsWith('.'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
  final keep = <String>{};
  for (final f in files) {
    final stem = f.path.replaceFirst(RegExp(r'\.(log|exit|exit\.tmp)$'), '');
    if (keep.length < 16) keep.add(stem);
    if (!keep.contains(stem)) f.deleteSync();
  }
}

/// Removes the logs and exit files of an earlier boot. `.run/proc/.boot`
/// names the boot the files are from; every channel rewrites it before it
/// starts a process, so a different one means all files are older.
void _clearOtherBoots(Directory dir, String boot, void Function(String) log) {
  final marker = File('${dir.path}/.boot');
  String? previous;
  try {
    previous = marker.readAsStringSync().trim();
  } on FileSystemException {
    // First start with this layout: nothing known, keep the files.
  }
  if (previous == boot) return;
  if (previous != null) {
    var removed = 0;
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path == marker.path) continue;
      f.deleteSync();
      removed++;
    }
    log('removed $removed process files of boot $previous');
  }
  marker.writeAsStringSync(boot);
}

const Map<String, ProcessSignal> _signals = {
  'TERM': ProcessSignal.sigterm,
  'KILL': ProcessSignal.sigkill,
  'INT': ProcessSignal.sigint,
  'HUP': ProcessSignal.sighup,
  'USR1': ProcessSignal.sigusr1,
  'USR2': ProcessSignal.sigusr2,
  'STOP': ProcessSignal.sigstop,
  'CONT': ProcessSignal.sigcont,
};

/// Compares tokens in time that depends only on their lengths.
bool _sameToken(String given, String expected) {
  if (given.length != expected.length) return false;
  var diff = 0;
  for (var i = 0; i < given.length; i++) {
    diff |= given.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return diff == 0;
}

bool _validEnvName(String name) =>
    name.isNotEmpty && !name.contains('=') && !name.contains('\x00');

String _newToken() {
  final random = Random.secure();
  final bytes = Uint8List.fromList(
    List.generate(32, (_) => random.nextInt(256)),
  );
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// The effective uid, from `/proc/self/status` (0 when run through su).
int? _uid() {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith('Uid:')) {
        return int.tryParse(line.split(RegExp(r'\s+'))[2]);
      }
    }
  } on FileSystemException {
    // Not Linux.
  }
  return null;
}

void _noLog(String _) {}
