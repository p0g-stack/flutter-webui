// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_webui_root/protocol.dart';
import 'package:web/web.dart' as web;

import '../root_channel.dart';

/// [ChannelTransport] for the page: `fetch` for `session.json` (served by the
/// manager from webroot), browser `WebSocket` for the channel.
final class WebChannelTransport implements ChannelTransport {
  final Random _random = Random();

  @override
  Future<String?> readSession() async {
    final origin = web.window.location.origin;
    final url = '$origin/$sessionFilePath?n=${_random.nextInt(1 << 30)}';
    try {
      final response = await web.window
          .fetch(url.toJS, web.RequestInit(cache: 'no-store'))
          .toDart;
      if (!response.ok) return null;
      final text = (await response.text().toDart).toDart;
      return text.trim().isEmpty ? null : text;
    } on Object {
      return null;
    }
  }

  @override
  Future<ChannelSocket> connect(Uri uri) {
    final socket = web.WebSocket(uri.toString())..binaryType = 'arraybuffer';
    final opened = Completer<ChannelSocket>();
    final channel = _WebSocket(socket);
    socket.onopen = ((web.Event _) => opened.complete(channel)).toJS;
    socket.onerror = ((web.Event _) {
      if (!opened.isCompleted) {
        opened.completeError(StateError('WebSocket refused'));
      }
    }).toJS;
    socket.onclose = ((web.CloseEvent _) {
      if (!opened.isCompleted) {
        opened.completeError(StateError('WebSocket closed'));
      }
      channel._controller.close();
    }).toJS;
    socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (data.typeofEquals('string')) {
        channel._controller.add((data as JSString).toDart);
      } else if (data.instanceOfString('ArrayBuffer')) {
        channel._controller.add((data as JSArrayBuffer).toDart.asUint8List());
      }
    }).toJS;
    return opened.future;
  }
}

final class _WebSocket implements ChannelSocket {
  _WebSocket(this._socket);

  final web.WebSocket _socket;
  final StreamController<Object> _controller = StreamController<Object>();

  @override
  Stream<Object> get frames => _controller.stream;

  @override
  void sendText(String text) => _socket.send(text.toJS);

  @override
  void sendBytes(Uint8List bytes) => _socket.send(bytes.toJS);

  @override
  Future<void> close() async => _socket.close();
}
