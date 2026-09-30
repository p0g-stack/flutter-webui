# flutter-webui

The Flutter embedder for KernelSU WebUI hosts, in Dart. A WebUI page runs in
the manager's WebView, which is not a browser: `ksu.exec` blocks the page,
missing files come back as empty 200s, back closes the activity unless
intercepted, and clipboard, files, share, insets and colors exist only through
the bridge. This repo makes stock Flutter APIs work there anyway.

WebUI is the standard (KernelSU, APatch, SukiSU, KSU Next). WebUI X (MMRL) is
its child: it adds, changes and removes features. Both are modelled here; apps
see the differences as capabilities, never as manager names.

## How

A `WidgetsFlutterBinding` subclass intercepts the standard channels
(`flutter/platform`, `navigation`, `lifecycle`, `settings`, `textinput`) and
answers them from the bridge instead of the browser, and feeds bridge insets
into window metrics. Plain Dart then works: `Clipboard`, `SystemNavigator.pop`,
`PopScope`, `WidgetsBindingObserver`, `MediaQuery`.

This sits above the stock `web_ui`. If a host limitation turns out to be below
the binding (renderer, pointer or IME behaviour of the WebView), a forked
`web_ui` lands in this same repo and the CLI switches to `--local-web-sdk`.

## Scope

In: the binding, the `webui` host and its `webuix` child, host detection, the
channel handlers, the ops transport over `ksu.exec`, the bootstrap page, fake
hosts for CI, module zip layout.

Out: the ops protocol and `Handler` (`surfaces`), app code.

## Proposed nest

```
spec/
  host.md             the bridge as observed per manager; the webui -> webuix delta as a table
packages/flutter_webui/lib/
  binding.dart        WebUiBinding: channel interception, window metrics
  host/detect.dart    probe optional methods; never manager names
  host/webui.dart     base: ksu.exec, $module, /internal/*.css, back interception
  host/webuix.dart    child: webui.* API, WX_* events, config.json; adds, changes, removes
  handlers/           platform, navigation, lifecycle, settings, text_input
  ops_transport.dart  OpsTransport over ksu.spawn (async, streaming); exec+poll fallback; detached jobs, attach, cancel
bootstrap/            index.html, ES5 gate, flutter_bootstrap.js, fallback.html
tools/
  fake_host/          profiles webui-min, webui, webuix, browser; reproduces the blocking exec
  module/             module.prop, customize.sh, config.json templates
```

## Rules

- The JS main thread is Flutter's UI thread. No handler may block it for
  longer than the bridge call it wraps; long work goes through `surfaces`
  jobs, never inline.
- `ksu.spawn` is the ops transport; `ksu.exec` with a callback is still
  synchronous on base KernelSU (the shell runs inside the bridge method) and
  only async on WebUI X. `Cap.opsAsync` derives from `spawn`'s presence.
- `spawn` joins args unquoted and posts every output line to the UI thread
  with the reader blocked until it runs: quote every arg here, throttle status
  lines in the worker, never stream raw command output through it.
- Anything the host cannot do is a `Cap` with a fallback, not an exception.
- `webuix` declares every delta from `webui` in `spec/host.md`; the code reads
  that table.

## License

LGPL-3.0-or-later with the LGPL-3.0 linking exception
(`LICENSE`, `LICENSE.exception`; SPDX `LGPL-3.0-or-later WITH LGPL-3.0-linking-exception`).
Apps may link this library statically or dynamically, private apps included,
without releasing their own code or shipping relinking material. Changes to
the library itself stay LGPL.
