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

## Nest (proposed)

```
packages/flutter_webui/      host detection, channel handlers, root-channel client, tests vs fakes
packages/flutter_webui_root/ the root channel executable (dart compile exe)
web_ui/                      VERSION (Flutter pin) + patches/
bootstrap/                   index.html, loader, shims/
fakes/                       fake host objects + devicelab recordings they replay
docs/hosts.md                host behaviour per manager, written once
```

## License

LGPL-3.0-or-later with the LGPL-3.0 linking exception
(`LICENSE`, `LICENSE.exception`; SPDX `LGPL-3.0-or-later WITH LGPL-3.0-linking-exception`).
Apps may link this library statically or dynamically, private apps included,
without releasing their own code or shipping relinking material. Changes to
the library itself stay LGPL.
