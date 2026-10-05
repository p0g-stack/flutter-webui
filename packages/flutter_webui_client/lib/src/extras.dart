// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:convert';

import 'bridge.dart';

/// A home-screen shortcut to the module's page, where the host can pin one
/// (WebUI X `webui.createShortcut()`). KernelSU-family managers offer the same
/// from their own module menu, so elsewhere [isSupported] is false and
/// [create] throws [UnsupportedError].
final class ModuleShortcut {
  ModuleShortcut(this._bridge);

  final HostBridge _bridge;

  /// Whether the host can pin a shortcut from the page.
  bool get isSupported => _bridge.webuiHas('createShortcut');

  /// Whether the module's shortcut is already pinned, as the host saw it when
  /// the page loaded; null where unknown.
  bool? get exists {
    if (!isSupported) return null;
    final value = _bridge.webuiProperty('hasShortcut');
    return value is bool ? value : null;
  }

  /// Asks the launcher to pin the shortcut; the launcher confirms with the
  /// user. Returns whether the host made the request.
  bool create() {
    if (!isSupported) {
      throw UnsupportedError(
        'This host cannot pin a shortcut from the page; KernelSU managers '
        'offer it in their module menu.',
      );
    }
    return _bridge.callWebui('createShortcut') == true;
  }
}

/// Which installed packages [HostPackages.list] returns.
enum PackageFilter { user, system, all }

/// One package from [HostPackages.info].
final class HostPackageInfo {
  const HostPackageInfo({
    required this.packageName,
    this.appLabel,
    this.versionName,
    this.versionCode,
    this.uid,
    this.isSystem,
    this.error,
    this.raw = const {},
  });

  factory HostPackageInfo.fromJson(Map<String, Object?> json) =>
      HostPackageInfo(
        packageName: '${json['packageName'] ?? ''}',
        appLabel: _string(json['appLabel']),
        versionName: _string(json['versionName']),
        versionCode: (json['versionCode'] as num?)?.toInt(),
        uid: (json['uid'] as num?)?.toInt(),
        isSystem: json['isSystem'] is bool ? json['isSystem']! as bool : null,
        error: _string(json['error']),
        raw: json,
      );

  final String packageName;
  final String? appLabel;
  final String? versionName;
  final int? versionCode;
  final int? uid;
  final bool? isSystem;

  /// Set when the host could not read the package (WebUI X: "Package not
  /// found or inaccessible").
  final String? error;

  /// Every field the host returned.
  final Map<String, Object?> raw;

  @override
  String toString() => 'HostPackageInfo($packageName, $appLabel, $versionName)';
}

String? _string(Object? v) => v is String ? v : null;

/// The manager's own package list (`ksu.listPackages` and
/// `ksu.getPackagesInfo`, on KernelSU and WebUI X), read without a root
/// shell. A fast path only: hosts filter what they return (WebUI X Play
/// builds list launchable apps only), so the root channel stays the way to
/// see every package. Where the host has neither, [isSupported] is false and
/// the methods throw [UnsupportedError].
final class HostPackages {
  HostPackages(this._bridge);

  final HostBridge _bridge;

  bool get isSupported =>
      _bridge.ksuHas('listPackages') && _bridge.ksuHas('getPackagesInfo');

  void _check() {
    if (!isSupported) {
      throw UnsupportedError('This host has no package list for the page.');
    }
  }

  /// Package names of [filter]'s packages.
  List<String> list([PackageFilter filter = PackageFilter.all]) {
    _check();
    final decoded = _decode(_bridge.callKsu('listPackages', [filter.name]));
    return decoded is List ? [for (final p in decoded) '$p'] : const [];
  }

  /// Details for [packageNames], in order.
  List<HostPackageInfo> info(List<String> packageNames) {
    _check();
    final decoded = _decode(
      _bridge.callKsu('getPackagesInfo', [jsonEncode(packageNames)]),
    );
    if (decoded is! List) return const [];
    return [
      for (final p in decoded)
        if (p is Map) HostPackageInfo.fromJson(p.cast<String, Object?>()),
    ];
  }

  /// The package's launcher icon as the host serves it to the WebView
  /// (`ksu://icon/<package>`, a PNG). It loads in an `<img>`; whether
  /// `Image.network` can fetch it depends on the host.
  Uri iconUri(String packageName) => Uri.parse('ksu://icon/$packageName');

  static Object? _decode(Object? raw) {
    if (raw is! String) return raw;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}
