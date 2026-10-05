// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

import 'dart:convert';

import 'bridge.dart';

/// A home-screen shortcut to the module's page, where the host can pin one
/// (WebUI X `webui.createShortcut()`). KernelSU-family managers offer the same
/// from their own module menu, so elsewhere [isSupported] is false and
/// [create] throws [UnsupportedError].
///
/// WebUI X draws the shortcut from the module's icon: `webuiIcon=<path>` (or
/// `icon=`) in `module.prop`, a PNG found first under `webroot/`, then under
/// the module directory. Without one [create] returns false and the host
/// shows its own "invalid icon" toast (v608; lab).
final class ModuleShortcut {
  ModuleShortcut(this._bridge);

  final HostBridge _bridge;

  /// Whether the host can pin a shortcut from the page.
  bool get isSupported => _bridge.webuiHas('createShortcut');

  /// Whether the module's shortcut is already pinned, as the host saw it when
  /// the page loaded; null where unknown.
  bool? get exists {
    if (!isSupported) return null;
    // A property, read when the page loads; WebUI X hands it through its
    // string dispatcher, so it may arrive as "true" or "false".
    return switch (_bridge.webuiProperty('hasShortcut')) {
      final bool value => value,
      'true' => true,
      'false' => false,
      _ => null,
    };
  }

  /// Asks the launcher to pin the shortcut; the launcher confirms with the
  /// user. Returns whether the host made the request: false when the
  /// launcher cannot pin, the shortcut exists, or the module has no icon
  /// (see the class comment); the host says which in a toast.
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

  /// Whether the host knew the package ([error] unset).
  bool get found => error == null;

  /// Every field the host returned.
  final Map<String, Object?> raw;

  @override
  String toString() => 'HostPackageInfo($packageName, $appLabel, $versionName)';
}

String? _string(Object? v) => v is String ? v : null;

/// The manager's own package list (`ksu.listPackages` and
/// `ksu.getPackagesInfo`, on KernelSU and WebUI X), read without a root
/// shell. A fast path only: each host answers from its own view, so the
/// root channel stays the way to see every package.
///
/// - KernelSU answers from its Superuser screen's app list (loaded by the
///   manager, without special apps), so a package outside it, such as
///   `android`, comes back with [HostPackageInfo.error] and no icon.
/// - WebUI X v608 answers from the package manager (Play builds: launchable
///   apps only).
///
/// A package the host did not find is data, not a failure: check
/// [HostPackageInfo.found] and fall back to the root channel. Where the host
/// has no list, [isSupported] is false and the methods throw
/// [UnsupportedError].
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
  /// (`ksu://icon/<package>`, a PNG; `Image.network` with
  /// `WebHtmlElementStrategy.prefer` loads it as an `<img>`). The host serves
  /// only packages its own list has: one from [list], or [info] with
  /// [HostPackageInfo.found]; any other answers 404.
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
