# Hosts

How each manager behaves for a Flutter web page, and what flutter-webui does
about it. Detection probes methods (`WebUiHost.detect`); the manager columns
are only for reading. Sources: manager source reads (KernelSU 08a3b08,
KernelSU-Next, WebUI-X-Portable ed569e19, APatch, KsuWebUIStandalone; see the
project research notes). **Nothing here is device-verified yet**; numbers and
"works" claims come from devicelab runs, named by device and manager, when
they exist.

## Serving

All hosts serve `/data/adb/modules/<id>/webroot` at `https://mui.kernelsu.org/`
through `WebViewAssetLoader` with root reads; `.wasm` is `application/wasm`.
KernelSU-family hosts send no headers and answer a missing file with an empty
200; WebUI X adds a CSP and ETags. No service workers, no COOP/COEP anywhere, so
the bootstrap forces single-threaded Skwasm, keeps hash routing and
`<base href="/">`, and the build must ship every asset (no CDN).

## What flutter-webui does per host

| Flutter concept | KernelSU, SukiSU | KernelSU Next, APatch | Standalone | WebUI X (Portable, MMRL) |
|---|---|---|---|---|
| Detected as | `webui` | `webui` | `webui` | `webuix` (`ksu.mmrl` or `window.webui`) |
| Safe-area padding | `insets.css` (`--safe-area-inset-*`), `ksu.enableEdgeToEdge(true)` | same, `ksu.enableInsets(true)` | none (host adds margins) | injected variables, `WX_ON_INSETS` (units unverified) |
| Lifecycle | page visibility, as `web_ui` (does `webView.onPause()` fire `visibilitychange`? devicelab) | same | same | `WX_ON_PAUSE` = hidden until `WX_ON_RESUME` (`visibilityState` stays `visible`) |
| Back | WebView history: `web_ui`'s history entries turn Back into `popRoute` | same | same | `WX_ON_BACK` = `history.back()` (needs `backInterceptor: "javascript"`) |
| `SystemNavigator.pop` at the root | history restored, then `ksu.exit()` | history restored; no exit method, the next Back closes | same | `webui.exit()` |
| Brightness | `prefers-color-scheme` | same | same | `$<id>.isDarkMode()` on start and resume |
| Clipboard | `navigator.clipboard`, write falls back to `execCommand('copy')`; read may be refused (a plugin can install a root-backed one) | same | same | same |
| Keyboard inset | `web_ui` visual viewport (the WebView resizes) | same | same | same (`WX_ON_KEYBOARD` not used: WebUI X also resizes, it would count twice) |
| Text scale | `textZoom = fontScale*100` reaches `web_ui` through the root font size (unverified) | same | same | same |
| Root channel start | `ksu.exec` (blocks the page for the fork only) | same | same | `ksu.exec` (async there) |
| Module id | `ksu.moduleInfo()` | Next: same; APatch: `<meta name="webui-module-id">` from the build | `moduleInfo()` | `moduleInfo()` |

## Lifetime

A manager screen is a browser tab: going home hides it (everything keeps
running), recreation or a kill discards it (fresh start, no restoration), and
swiping the manager away closes it (attached root processes end with their
connection; an app's detached root process ends itself after its grace
window).

- KernelSU handles configuration changes itself; Next and WebUI X recreate the
  activity (page reload) on rotation, dark mode, font scale.
- WebUI X stops page timers while paused (`pauseTimers()`, hard-coded). Work
  that must progress while hidden runs in a root process.

## What the module must set (flutter_p0g's `webui/` template)

WebUI X `webroot/config.json`:

```json
{
  "backInterceptor": "javascript",
  "exitConfirm": false,
  "killShellWhenBackground": false,
  "pullToRefresh": false
}
```

- `backInterceptor: "javascript"` sends Back to the page (`WX_ON_BACK`).
- `exitConfirm: false`: closing at the root route is closing a tab, no prompt.
- `killShellWhenBackground: false` keeps the root shell across Home.
- The default CSP allows `connect-src *` (the root channel's WebSocket); a
  module that narrows it must keep `ws://127.0.0.1:*`. The dev entry
  (`bootstrap/dev.html`) also needs `http://127.0.0.1:*` in `script-src` and
  `default-src`.

## Open (devicelab)

- Whether `webView.onPause()` fires `visibilitychange` on KernelSU-family hosts.
- Loopback from the page: Chromium treats 127.0.0.1 as trustworthy (no
  mixed-content block, inferred); whether newer WebViews prompt for Local
  Network Access.
- Whether WebUI X serves `/.run/session.json` from webroot (it maps
  `/.<modId>/` to the module directory; a module id `run` would collide).
- `WX_ON_INSETS` units; `textZoom` effect; clipboard read and write per host.
- The Dart runtime on Android (Android-built `dartaotruntime`, or the linux one
  through its bundled loader).
