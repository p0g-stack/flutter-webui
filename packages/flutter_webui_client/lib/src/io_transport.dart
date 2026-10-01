// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'root_channel.dart';

/// [ChannelTransport] over `dart:io`, for tests and host-side tools.
final class IoChannelTransport implements ChannelTransport {
  IoChannelTransport({this.origin});

  /// Sent as the `Origin` header, as a page would.
  final String? origin;

  @override
  Future<ChannelSocket> connect(Uri uri) async {
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: {'origin': ?origin},
    );
    return _IoSocket(socket);
  }
}

final class _IoSocket implements ChannelSocket {
  _IoSocket(this._socket);

  final WebSocket _socket;

  @override
  late final Stream<Object> frames = _socket.map(
    (f) => f is String ? f : Uint8List.fromList(f as List<int>),
  );

  @override
  void sendText(String text) => _socket.add(text);

  @override
  void sendBytes(Uint8List bytes) => _socket.add(bytes);

  @override
  Future<void> close() => _socket.close();
}
