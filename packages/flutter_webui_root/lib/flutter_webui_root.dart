// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// The flutter-webui root channel (server side). See `docs/root-channel.md`.
library;

export 'protocol.dart';
export 'src/server.dart' show ChannelLimits, ChannelTimings, RootChannelServer;
export 'src/launcher.dart'
    show ChannelLauncher, ChannelSpawner, LauncherException;
export 'src/run_state.dart'
    show
        InstanceLock,
        KsudModuleConfig,
        ModuleConfig,
        RunModes,
        SessionStore,
        StartLock,
        readBootId,
        setMode,
        staleReason;
