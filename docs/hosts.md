# Hosts

How each manager behaves for a Flutter web page, and what flutter-webui does
about it. Detection probes methods (`WebUiHost.detect`); the manager columns
are only for reading. Sources: manager source reads (KernelSU 08a3b08,
KernelSU-Next, WebUI-X-Portable ed569e19, APatch, KsuWebUIStandalone; see the
project research notes). Only the "Verified" section below is device-verified; numbers and
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

| Flutter concept | KernelSU, SukiSU | KernelSU Next, APatch | Standalone | WebUI X (Portable, MMRL): v438 and Play v608 |
|---|---|---|---|---|
| Detected as | `webui` | `webui` | `webui` | `webuix` (`ksu.mmrl` or `window.webui`) |
| Safe-area padding | `insets.css` (`--safe-area-inset-*`), `ksu.enableEdgeToEdge(true)` | same, `ksu.enableInsets(true)` | none (host adds margins) | injected `--safe-area-inset-*` (v608: CSS only); `WX_ON_INSETS` on v438 (units unverified) |
| Lifecycle | page visibility, as `web_ui`: `webView.onPause()` hides the page (by Chromium source), also for its own file chooser | page visibility: no `onPause()`, Home hides the window (inferred) | same | page visibility (`onPause()` hides the page; v608 sends no events); v438 also `WX_ON_PAUSE` = hidden until `WX_ON_RESUME` |
| Back | WebView history: `web_ui`'s entries turn Back into `popRoute`; Chromium leaves entries pushed without a gesture out of `canGoBack()`, so on the first gesture the plugin re-pushes the "flutter" entry and afterwards answers Back by going forward to it (no new push) | same | same | as KernelSU with `backInterceptor: "native"` (WebView history; v608 posts no `WX_ON_BACK`); pages installed with `"javascript"` on v438 still get `WX_ON_BACK` = `history.back()` |
| Predictive back | none: the gesture commits as a Back | same | same | v608: `document.addMXEventListener` `backStarted` / `backProgressed` / `backCancelled` become `flutter/backgesture` `startBackGesture` / `updateBackGestureProgress` / `cancelBackGesture`, and the Back that commits the swipe becomes `commitBackGesture`, so a route with a predictive transition follows the finger. v608 forwards the progress in every `backInterceptor` mode (the callback is registered unconditionally, `enableOnBackInvokedCallback="true"`); only the commit differs: `"native"` = history as on KernelSU, `"javascript"` = history, then `backPressed` at the root. v438: no `addMXEventListener` (review of 2026-10-05) |
| Home-screen shortcut | none (the manager's own module menu) | same | same | `WebUi.shortcut`: `webui.createShortcut()` and the `webui.hasShortcut` property (a value, not a function) where present (v608); unsupported elsewhere. v608 draws the shortcut from `webuiIcon=` (or `icon=`) in `module.prop`, a PNG path under `webroot/` or the module directory; without it an "invalid icon" toast and no pin (lab 2026-10-05). With an icon the pin dialog opens and the pin works, but the page learns nothing: `createShortcut()` returns a boxed `Boolean` that WebView's bridge does not pass as a boolean (`create()` answers null), and `hasShortcut` checks `shortcut_<id>_<engine>` while the pin is `shortcut_<id>`, so it stays false (lab 2026-10-05, `dumpsys shortcut`). The dialog and toasts are the user's feedback |
| Package list | `WebUi.packages`: `ksu.listPackages` / `getPackagesInfo`, icons at `ksu://icon/<pkg>`, all from the Superuser screen's app list (no special apps: `android` is "Package not found" and its icon a 404, lab 2026-10-05); a fast path, the root channel stays the full list | same | same | same on v608 (Play builds list launchable apps only; the official build lists all; `kernelsu.permission.PACKAGES` exists but v608 does not check it); none on v438 |
| `SystemNavigator.pop` at the root | history restored, then `ksu.exit()` | history restored; no exit method, the next Back closes | same | `webui.exit()` where present (v438, v608); without it (upstream master) as Next |
| Brightness | the luminance of `--background` in `/internal/colors.css` when served (Monet colour modes 3 to 6, or the Material UI), which carries a forced manager theme; else `prefers-color-scheme` (the system's: forced light or dark without Monet does not reach the page) | `colors.css` (Android 12+), which Next builds from the system night mode: the system's either way | `prefers-color-scheme` | `colors.css` as KernelSU (still served on v608), else `$<id>.isDarkMode()` |
| Clipboard | `navigator.clipboard`: write is auto-granted (fallback `execCommand('copy')`); programmatic read is always denied by WebView, user paste in a field works (a plugin can install another clipboard with `WebUiClipboard.use`, such as `clipboard_webui`'s) | same | same | same (its permission handler never sees clipboard read) |
| Keyboard inset | `web_ui` visual viewport (the WebView resizes, animated) | likely none: edge-to-edge, no soft-input mode, insets consumed without `ime()`, so the keyboard may cover the field (by source; an upstream fix if confirmed) | as KernelSU | `web_ui` visual viewport (`windowResize: true` resizes the WebView; `WX_ON_KEYBOARD` not used: toggle-only and it would count twice) |
| Locale | `navigator.languages` = the manager's locale list (per-app language on Android 13+) plus en-US, as a browser reports its own | same; before Android 13 Next's in-app language does not reach it | same | same |
| Fonts | no system fonts; `web_ui` loads fallbacks from `fonts/` in the module (`web_ui/tool/fallback_fonts.dart`) | same | same | same |
| Accessibility | as Chrome on Android: TalkBack reads the DOM, "Enable accessibility" placeholder once per load | same | same | same |
| Text scale | `textZoom = fontScale*100` reaches `web_ui` through the root font size (unverified) | same | same | same |
| Root channel start | `ksu.exec` (blocks the page for the fork only) | same | same | `ksu.exec` (async there). v608 gates it behind `kernelsu.permission.SHELL` in `permissions`: without it the call never answers and asks the user once (Allow reloads the page; Reject stands until the manager restarts); the page sees `""`, not null, because v608's method dispatcher turns a null result into an empty string. After 2 s without an answer the client runs the one-argument `exec('echo flutter-webui')`: a refusing host answers `""` (or null), so it fails with `RootChannelException('shell-refused')` instead of a 30 s timeout (the first probe, `exec('true')`, could not tell `""` from a refusal: lab 2026-10-05, 63 s after Reject) |
| Module id | `<meta name="webui-module-id">` from the build; `ksu.moduleInfo()` only without it (it runs `ksud module list` through the root shell on the page thread) | same | same | same |

## Lifetime

A manager screen is a browser tab: going home hides it (everything keeps
running), recreation or a kill discards it (fresh start, no restoration), and
swiping the manager away closes it (attached root processes end with their
connection; an app's detached root process ends itself after its grace
window).

- KernelSU handles configuration changes itself; Next and WebUI X recreate the
  activity (page reload) on rotation, dark mode, font scale.
- WebUI X v438 stops page timers while paused (`pauseTimers()`, hard-coded);
  v608 no longer does. Work that must progress while hidden runs in a root
  process either way.

## What the module must set (flutter_p0g's `webui/` template)

WebUI X `webroot/config.json`:

```json
{
  "permissions": ["kernelsu.permission.SHELL"],
  "backInterceptor": "native",
  "exitConfirm": false,
  "windowResize": true,
  "killShellWhenBackground": false,
  "pullToRefresh": false
}
```

- `permissions: ["kernelsu.permission.SHELL"]`: v608 refuses `ksu.exec`
  (and with it the root channel) without it; older builds and other managers
  ignore the key.
- `backInterceptor: "native"`: Back is WebView history, as on the KernelSU
  family, on every version. `"javascript"` worked on v438 only (`WX_ON_BACK`);
  on v608 it leaves Back dead whenever `canGoBack()` is false, unless the page
  listens for `backPressed`, which flutter-webui does. Predictive back needs
  no mode: v608 sends the swipe progress in `"native"` too.
- `exitConfirm: false`: closing at the root route is closing a tab, no prompt.
- `windowResize: true` (the default, set so it is not lost) resizes the WebView
  for the keyboard, which is how `web_ui` sees it.
- `killShellWhenBackground: false` keeps the root shell across Home.
- The default CSP allows `connect-src *` (the root channel's WebSocket); a
  module that narrows it must keep `ws://127.0.0.1:*`. The dev entry
  (`bootstrap/dev.html`) also needs the dev server, `http://127.0.0.1:<port>`,
  in `script-src` and `style-src` (or `default-src`), and `'unsafe-inline'`
  for its inline scripts (docs/dev.md).

## Verified (devicelab)

KernelSU 3.3.0, Android 15 x86_64 emulator, WebView 124.0.6367.219
(devicelab managers, Actions run 36831416564, counter module 0.1.2):

- The page loads at `https://mui.kernelsu.org/index.html` and draws edge to
  edge; `--safe-area-inset-top` is 24px.
- Home: `visibilitychange` to hidden, return: visible; no `focus`/`blur`.
  While hidden, timers throttle to about one tick a second and fetches
  complete. Back at the root route closes the WebUI.
- Root channel (then found through `webroot/.run/session.json`; `root start`
  now prints the session instead): `ksu.exec` of `root start` returns in 206 ms, `session.json`
  is served 62 ms later, the WebSocket hello reports uid 0. The channel runs
  as `u:r:ksu:s0` through the glibc loader. Page `fetch` and WebSocket to
  127.0.0.1 work on this WebView (older than Local Network Access).
- The WebView's sockets belong to the manager's own uid (10209 here; seen
  from root in `/proc/net/tcp`), not a sandbox uid.
- First frame (software GL, relative only): warm 1309 ms (2357 ms with 0.1.0,
  which called `ksu.moduleInfo()` at start).

WebUI X Portable with root, same emulator (runs 36833152967, 36833446476):

- The root channel starts through `ksu.exec`; the page reads `session.json`
  and gets the hello with uid 0.
- While paused (`pauseTimers()`), `setInterval` stops completely but fetch
  callbacks still run. Sockets belong to its uid (10210).
- `ksu` and `webui` are defined after document start. At the root route the
  page has one history entry, so Back reaches `webui.exit()` through a direct
  `popRoute` (020ab92); verified with counter 0.1.5: WebUIActivity closes.
- `ksu.moduleInfo()` can throw a Java exception (a null module entry); the
  id then comes from the build's `<meta>`.

KernelSU 3.3.0, demo 0.9 (flutter-webui 020ab92): Back from a pushed route
(two routes deep) closed the WebUI, where WebUI X returned to the home route.
KernelSU enables its Back handler from `canGoBack()`, read in
`doUpdateVisitedHistory`, and Chromium's history intervention leaves
`web_ui`'s startup entry out of it because it was pushed without user
activation. Reproduced in the fake host and fixed in the plugin (Back entry
kept reachable after the first gesture, 8deba51). Verified with demo e511324
(run 36857376482): the first Back returns to the home route, the second at
the root closes WebUIActivity.

KernelSU Next v3.4.0, same demo (run 36863177354): Back from a pushed route
returns to the home route, but at the root it took more than one extra Back
to close. Next has no exit method, so `SystemNavigator.pop` only unwinds
history (as in a browser tab, where the next Back leaves the page), and with
the plugin's origin entry the unwinding stopped one entry short; a tap also
unmarks skipped entries, so Next's live `canGoBack()` stayed true. Since
9ee7918 the unwinding reaches the page's first entry, so the Back after
the root pop closes the page. Verified with demo 4ecb310 (run 36867879913),
with KernelSU 3.3.0 and WebUI X v438 unchanged (run 36867884161).

## Open (devicelab)

- WebUI X v608 (Play, sha256 `ae88a8ca…`): Back from a pushed route and at the
  root with `"native"`; the SHELL overlay with and without the key, and the
  fast `shell-refused` error after Reject (fake host only so far:
  `--host webuix608 [--shell-refused]`).
- WebUI X v608 predictive back (fake host only: `--events swipe,swipe-cancel`):
  that the swipe events reach the page in `"native"` mode on Android 14+ and
  the route follows the finger; that the commit pops one route; that a
  cancelled swipe leaves the route; a swipe at the root closes the page. Also
  `WebUi.shortcut.create()` pinning, and `WebUi.packages` on v608 and KernelSU.


- `visibilityState`, `focus`, `blur` on Next and WebUI X, and on KernelSU for
  recents, screen off and the file chooser.
- The keyboard on KernelSU-Next: does `viewInsets.bottom` change when a field
  near the bottom is focused?
- Loopback from the page: no mixed-content block for `http://127.0.0.1` (seen
  in Chromium 141), but Chromium 141 gates a public page's requests to
  loopback behind the Local Network Access permission (docs/dev.md); whether
  a manager's WebView enforces it, and for the root channel's WebSocket too.
- `WX_ON_INSETS` units; `textZoom` effect; clipboard `writeText` and long-press
  paste per host; offline emoji with the bundled fonts.
- An Android-built `dartaotruntime` (the linux one through its bundled loader
  works, above).
- Full per-topic checks: `docs/parity.md`.
