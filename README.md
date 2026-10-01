# flutter-webui

The Flutter embedder for KernelSU-style WebUI hosts, in Dart. A module's page
runs inside the root manager's WebView (KernelSU, KernelSU Next, SukiSU, APatch,
WebUI X / MMRL). This repo makes a stock Flutter web app behave there the way it
does in a browser tab.

## Parity reference

WebUI is a web page, so its peer is Flutter's own `web_ui`, not Android. Parity
means a stock app (no WebUI-specific code) behaves as it does as a Flutter web
app in a browser tab, and the staple plugins work (through `webui-packages`).

- Going to the home screen is switching tabs: `AppLifecycleState` goes `hidden`
  and back to `resumed`, as `web_ui` does on `visibilitychange`.
- The manager recreating or killing its screen is a discarded tab: a fresh
  start. No `flutter/restoration`, as in `web_ui`.
- Back at the root route closes the tab (`ksu.exit` / `webui.exit`).

## How

- **Patched `web_ui`** (pinned Flutter release, patch series): handlers sit
  where `web_ui` has them, so `main()` is stock.
- **Host detection** probes optional bridge methods; a manager's name or
  version never selects behaviour. WebUI X is a child of WebUI: its deltas are a
  table.
- **Bootstrap** (`index.html`, loader) for the manager's fixed origin, plus
  Web-API shims backed by the root side where a WebView lacks an API.
- **Root channel**: a small Dart executable started once through the bridge.
  It serves one WebSocket on 127.0.0.1 (port and token in
  `webroot/.run/session.json`), replacing the bridge's blocking `exec`, flaky
  `spawn`, quoting limits and polling. It offers a stable channel and process
  launch, nothing else; plugins and apps build on it.

## Scope

In: the patched `web_ui` and its handlers, host detection, the bootstrap and
shims, the root channel, host fakes for tests, per-host notes.

Out: plugins (`webui-packages`), the build/packaging tool (`flutter_p0g`,
which also adds the `webui/` platform folder to an app), app code, work that
must outlive the page (the app's own root process).

## Layout

```
packages/flutter_webui/       web plugin: host detection, handlers on the patched web_ui hooks,
                              root-channel client (WebUi.connectRootChannel), tests vs fakes
packages/flutter_webui_root/  the root channel (Dart, AOT snapshot) and its launcher (module/root)
web_ui/                       VERSION (Flutter pin), patches/, tool/build_web_sdk.dart
bootstrap/                    index.html, flutter_bootstrap.js, flutter_webui.js/.css, dev.html
docs/                         hosts.md (behaviour per manager), root-channel.md (contract v1)
```

## Using it

An app needs three things, which `flutter_p0g` provides (`create .` adds the
`webui/` platform folder, `precache` the SDK, `build webui` the module):

1. **The patched web SDK.** `dart run web_ui/tool/build_web_sdk.dart --flutter
   <flutter 3.47.5> --out <dir>` applies `web_ui/patches` to the release's
   `web_ui` sources and rebuilds the platform kernels and DDC modules with the
   Dart SDK's own tools (about 20 s, no engine build). Overlay `<dir>` on
   `<flutter>/bin/cache`.
2. **`flutter_webui` as a dependency.** Its web plugin registrant installs the
   handlers before `main()`; app code stays stock.
3. **The bootstrap** laid over `web/`, built with
   `flutter build web --release --no-web-resources-cdn --pwa-strategy=none`.

The patches add `dart:ui_web` hooks (`setHostViewPadding`,
`setHostAppLifecycleState`, `setHostPlatformBrightness`, `setHostExitHandler`,
`setHostClipboard`, `setHostKeyboardInset`) that keep today's behaviour unless
an embedding sets them, so they are upstreamable as is.

## License

LGPL-3.0-or-later with the LGPL-3.0 linking exception
(`LICENSE`, `LICENSE.exception`; SPDX `LGPL-3.0-or-later WITH LGPL-3.0-linking-exception`).
Apps may link this library statically or dynamically, private apps included,
without releasing their own code or shipping relinking material. Changes to
the library itself stay LGPL.
