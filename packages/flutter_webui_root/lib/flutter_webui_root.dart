// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// The flutter-webui root channel (server side). See `docs/root-channel.md`.
library;

export 'protocol.dart';
export 'src/server.dart' show ChannelTimings, RootChannelServer;
export 'src/session_file.dart' show InstanceLock, SessionFile, readBootId;
