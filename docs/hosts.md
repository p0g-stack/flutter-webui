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
| Lifecycle | page visibility, as `web_ui`: `webView.onPause()` hides the page (by Chromium source), also for its own file chooser | page visibility: no `onPause()`, Home hides the window (inferred) | same | `WX_ON_PAUSE` = hidden until `WX_ON_RESUME`; `onPause()` also hides the page by source, so this agrees |
| Back | WebView history: `web_ui`'s history entries turn Back into `popRoute` | same | same | `WX_ON_BACK` = `history.back()` (needs `backInterceptor: "javascript"`) |
| `SystemNavigator.pop` at the root | history restored, then `ksu.exit()` | history restored; no exit method, the next Back closes | same | `webui.exit()` |
| Brightness | `prefers-color-scheme` | same | same | `$<id>.isDarkMode()` on start and resume |
| Clipboard | `navigator.clipboard`: write is auto-granted (fallback `execCommand('copy')`); programmatic read is always denied by WebView, user paste in a field works (a plugin can install a root-backed read) | same | same | same (its permission handler never sees clipboard read) |
| Keyboard inset | `web_ui` visual viewport (the WebView resizes, animated) | likely none: edge-to-edge, no soft-input mode, insets consumed without `ime()`, so the keyboard may cover the field (by source; an upstream fix if confirmed) | as KernelSU | `web_ui` visual viewport (`windowResize: true` resizes the WebView; `WX_ON_KEYBOARD` not used: toggle-only and it would count twice) |
| Locale | `navigator.languages` = the manager's locale list (per-app language on Android 13+) plus en-US, as a browser reports its own | same; before Android 13 Next's in-app language does not reach it | same | same |
| Fonts | no system fonts; `web_ui` loads fallbacks from `fonts/` in the module (`web_ui/tool/fallback_fonts.dart`) | same | same | same |
| Accessibility | as Chrome on Android: TalkBack reads the DOM, "Enable accessibility" placeholder once per load | same | same | same |
| Text scale | `textZoom = fontScale*100` reaches `web_ui` through the root font size (unverified) | same | same | same |
| Root channel start | `ksu.exec` (blocks the page for the fork only) | same | same | `ksu.exec` (async there) |
| Module id | `<meta name="webui-module-id">` from the build; `ksu.moduleInfo()` only without it (it runs `ksud module list` through the root shell on the page thread) | same | same | same |

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
  "windowResize": true,
  "killShellWhenBackground": false,
  "pullToRefresh": false
}
```

- `backInterceptor: "javascript"` sends Back to the page (`WX_ON_BACK`).
- `exitConfirm: false`: closing at the root route is closing a tab, no prompt.
- `windowResize: true` (the default, set so it is not lost) resizes the WebView
  for the keyboard, which is how `web_ui` sees it.
- `killShellWhenBackground: false` keeps the root shell across Home.
- The default CSP allows `connect-src *` (the root channel's WebSocket); a
  module that narrows it must keep `ws://127.0.0.1:*`. The dev entry
  (`bootstrap/dev.html`) also needs the dev server, `http://127.0.0.1:<port>`,
  in `script-src` and `style-src` (or `default-src`), and `'unsafe-inline'`
  for its inline scripts (docs/dev.md).

## Open (devicelab)

- `visibilityState`, `focus`, `blur` per host for Home, recents, screen off,
  the file chooser (KernelSU and WebUI X should go hidden by source; Next by
  window visibility, inferred).
- The keyboard on KernelSU-Next: does `viewInsets.bottom` change when a field
  near the bottom is focused?
- Loopback from the page: no mixed-content block for `http://127.0.0.1` (seen
  in Chromium 141), but Chromium 141 gates a public page's requests to
  loopback behind the Local Network Access permission (docs/dev.md); whether
  a manager's WebView enforces it, and for the root channel's WebSocket too.
- Whether WebUI X serves `/.run/session.json` from webroot (it maps
  `/.<modId>/` to the module directory; a module id `run` would collide).
- `WX_ON_INSETS` units; `textZoom` effect; clipboard `writeText` and long-press
  paste per host; offline emoji with the bundled fonts.
- Who reads `webroot/` when the manager serves it: root (a root shell or
  libsu `SuFile`, as the source reads say) or the manager's own uid. If every
  host reads as root, `webroot/.run/session.json` can go from 0644 to 0600
  and `.run/` from 0711 to 0700 (`RunModes` in `flutter_webui_root`); check a
  page still finds the channel on each host after the change.
- The Dart runtime on Android (Android-built `dartaotruntime`, or the linux one
  through its bundled loader).
- Full per-topic checks: `docs/parity.md`.
