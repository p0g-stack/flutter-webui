<!-- Copyright 2026 The p0g-stack authors.
     SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception -->

# Dev loop

How `flutter_p0g run webui` runs an app on a phone with hot restart, what its
dev server must do, and the fake host (`tool/fake_host/`) that runs a module
page in headless Chromium for checks and CI.

Verified here means: Playwright 1.56.1, Chromium 141.0.7390.37 (headless),
Flutter 3.47.5 with the patched web SDK, the counter app, the page served at
`https://mui.kernelsu.org/` by route interception. **Nothing on this page is
device-verified**; device items are listed at the end.

## Shape

```
phone: manager WebView                         dev machine
https://mui.kernelsu.org/index.html  (= bootstrap/dev.html, from the module)
  ksu bridge, /internal/insets.css, history     stay on the manager origin
  flutter_webui.js, flutter_bootstrap.js,  ---> http://127.0.0.1:P/  dev server (CORS)
  main.dart.js, DDC modules, assets, wasm        |  adb reverse tcp:P tcp:P
  ws://127.0.0.1:P/$dwdsSseHandler  -------->    '-> flutter run -d web-server (DDC) on 127.0.0.1:U
```

The page never leaves the manager's origin, so the bridge (`ksu`, `webui`,
`$<id>`), `insets.css`, the `WX_*` messages and the root channel behave as in
a release build. Only the app's files come from the dev machine.

## What `run webui` does

1. Builds and installs the module once as for release (`build webui`), so the
   module directory holds the root channel and anything else the app's root
   side needs, then replaces `webroot/index.html` with `bootstrap/dev.html`
   with both metas filled: `webui-module-id` (the module id) and
   `webui-dev-server` (`http://127.0.0.1:P/`). A manager opens `index.html` and
   cannot pass `?dev=`; `dev.html?dev=http://127.0.0.1:P/` is for browsers and
   the fake host.
2. For WebUI X, ships `webroot/config.json` as in docs/hosts.md and a CSP that
   allows the dev server (below).
3. Starts `flutter run -d web-server --web-hostname 127.0.0.1 --web-port U
   --no-web-resources-cdn` in the app (the app's `web/` carries the bootstrap,
   the build depends on `flutter_webui`, the SDK is the patched one), and a dev
   server on `127.0.0.1:P` in front of it. `tool/fake_host/dev_server.mjs
   --proxy http://127.0.0.1:U --port P` is the reference implementation of
   everything in the next section; `flutter_p0g` may embed its own.
4. `adb reverse tcp:P tcp:P`. One port is enough: the debug service's
   WebSocket goes through the dev server too (see Host below).
5. Forwards `r` / `R` to `flutter run`.

## What the dev server must do

Checked with `dev_server.mjs` switches (`--no-cors`, `--no-pna`) and the fake
host; the failing case is quoted where there is one.

| Requirement | Why | Verified |
|---|---|---|
| `Access-Control-Allow-Origin: https://mui.kernelsu.org` (or `*`) on every response, errors included; `Vary: Origin` | CanvasKit/Skwasm `.wasm` (fetch), `canvaskit.js`/`skwasm.js`/`main.dart.mjs` (dynamic `import()`), `main.dart.wasm`, `assets/FontManifest.json`, `AssetManifest*`, fonts and other assets (fetch), `reloaded_sources.json` (fetch) are CORS requests. Classic `<script>` and `<link>` loads (`flutter_webui.js`, `flutter_bootstrap.js`, `main.dart.js`, `dart_sdk.js`, the DDC module scripts, `flutter_webui.css`) are not, but sending it everywhere is simplest | Without it: `Access to fetch at 'http://127.0.0.1:8081/canvaskit/chromium/canvaskit.wasm' from origin 'https://mui.kernelsu.org' has been blocked by CORS policy: No 'Access-Control-Allow-Origin' header`, no first frame. With it: first frame for dart2js debug, dart2wasm release (Skwasm) and DDC |
| No credentials | Every request is anonymous (fetch with same-origin credentials, `import()`, script tags): no `Access-Control-Allow-Credentials`, `*` is fine | yes (dev server never sends it) |
| No preflight needed; answer `OPTIONS` with 204 anyway | All requests are plain GETs without custom headers; no `OPTIONS` arrived in any run | yes |
| Private Network Access: answer a preflight carrying `Access-Control-Request-Private-Network: true` with `Access-Control-Allow-Private-Network: true` | Older Chromium sent PNA preflights for public-to-local subresources. Chromium 141 sends none, even with `--enable-features=PrivateNetworkAccessSendPreflights,PrivateNetworkAccessRespectPreflightResults`; the server with `--no-pna` loads the same | header unobserved; kept for older WebViews (harmless) |
| Content types: `.wasm` `application/wasm`, `.js`/`.mjs` `text/javascript`, `.json`, fonts | `WebAssembly.compileStreaming` needs `application/wasm`; module scripts need a JS type | yes |
| `Cache-Control: no-store` | A restarted app must not get a cached module | by design |
| Pass the `Host` header to `flutter run` unchanged, and forward WebSocket upgrades | The DDC debug client opens `ws://<Host>/$dwdsSseHandler`; with the upstream's host it bypasses the dev server and needs a second forwarded port | yes: with `Host: 127.0.0.1:U` the page dialled `ws://127.0.0.1:U/...` |
| Rewrite `reloaded_sources.json`: make each root-relative `src` absolute (`http://<Host>/packages/...`) | On hot restart the DDC loader loads the changed modules from these paths; relative, they resolve against the manager origin (where KernelSU answers an empty 200) | yes: before, `/packages/counter/main.dart.lib.js` hit the manager; after, hot restart and hot reload apply |
| Add Roboto to `assets/FontManifest.json` and serve `assets/fonts/fallback/Roboto-Regular.ttf` from `<flutter>/engine/src/flutter/txt/third_party/fonts/` | `flutter build web --no-web-resources-cdn` bundles it, `flutter run` does not, and the bootstrap keeps the engine off gstatic (fallbacks come from `fonts/` on the dev server, `--fonts`): without it no text renders | yes (blank text before, text after) |

`bootstrap/dev.html` itself:

- Has no `<base>`. `web_ui` resolves its history URLs against the base, and a
  base on the dev server made `replaceState` throw (`A history state object with
  URL 'http://127.0.0.1:8080/dev.html?...' cannot be created in a document with
  origin 'https://mui.kernelsu.org'`). Instead it sets
  `window.flutterWebUiDevServer`, and `bootstrap/flutter_bootstrap.js` passes
  `entrypointBaseUrl`, `assetBase` and `canvasKitBaseUrl` under it to the
  loader, and `fontFallbackBaseUrl` as `<dev server>/fonts/`: a dev module is
  only `dev.html`, so the dev server serves the fallback fonts too
  (`web_ui/tool/fallback_fonts.dart --out <dir>`, `dev_server.mjs --fonts
  <dir>`). Tools add no loader shim of their own.
- Loads `/internal/insets.css` from the manager and `flutter_webui.css` / `.js`
  and `flutter_bootstrap.js` from the dev server, and shows an error with the
  `adb reverse` hint when the dev server cannot be reached.
- Resolves `window.$reloadedSourcesPath` (set by the debug client, relative)
  against the dev server.

### Mixed content and loopback

- An `https://` page loading `http://127.0.0.1:P/` is not blocked as mixed
  content: `127.0.0.1` is a potentially trustworthy origin (W3C Secure Contexts,
  "Is origin potentially trustworthy?"; Chromium's
  `network::IsUrlPotentiallyTrustworthy`). Verified: scripts, fetches and wasm
  from `http://127.0.0.1` all load into the `https://mui.kernelsu.org` page.
- **Local Network Access** (Chromium 141): a public page reaching loopback
  needs the `local-network-access` permission. Headless Chromium denies it:
  ``Access to script at 'http://127.0.0.1:8080/flutter_webui.js' from origin
  'https://mui.kernelsu.org' has been blocked by CORS policy: Permission was
  denied for this request to access the `unknown` address space.``, for the
  stylesheet and scripts alike, whatever headers the server sends. Granting the
  permission (`context.grantPermissions(['local-network-access'])`) or
  `--disable-features=LocalNetworkAccessChecks` lets everything load. A
  route-fulfilled page counts as public here, as a `WebViewAssetLoader`
  response presumably does on a phone.
- Android WebView (inferred, devicelab): WebViews before LNA had PNA in
  warning-only mode at most, so the CORS header is all they need. WebView
  builds with LNA (Chromium 141+) have no permission prompt of their own; if LNA
  is enforced there, the manager would have to grant it (for example through
  `WebChromeClient.onPermissionRequest`), which no manager does today. Check
  on the device's WebView version before relying on the dev loop.

### WebUI X CSP

WebUI X serves pages with a CSP. With `fake_host --csp`:

- `default-src 'self' 'unsafe-inline'; connect-src *`: blocked
  `flutter_webui.css` (`style-src-elem`) and `flutter_webui.js`
  (`script-src-elem`).
- adding `http://127.0.0.1:P` to `default-src`: blocked `wasm-eval` (Flutter
  needs `'wasm-unsafe-eval'` in any build, not only dev).
- `default-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' http://127.0.0.1:P;
  connect-src *`: first frame.

So the dev module's CSP needs `http://127.0.0.1:P` in `script-src` and
`style-src` (or `default-src`), `'unsafe-inline'` for dev.html's inline
scripts, and `connect-src` covering `http://127.0.0.1:P` and
`ws://127.0.0.1:P` (WebUI X's default `connect-src *` does). How WebUI X lets a
module set its CSP is per docs/hosts.md; the exact default policy is not
re-checked here.

### Hot restart and hot reload

DDC through `dev.html` and `dev_server.mjs --proxy`, in Chromium: first frame in
4 to 7 s (about 460 module scripts), `R` restarts in about 350 ms and `r`
reloads in about 230 ms, with the edit visible. Each hot restart logs one
debug-mode assertion from the engine (`Trying to render a disposed
EngineFlutterView`) and then runs normally; not investigated. A hot restart
re-runs `main()`: the handlers ask the bridge again (`ksu.moduleInfo()`,
`ksu.enableEdgeToEdge(true)`). What happens to open root-channel connections
across a restart is untested.

Untested on a device: everything in this section, the cost of ~460 script
loads over `adb reverse`, whether WebUI X's `pauseTimers()` while hidden
stalls the debug connection, and what a manager's page reload (rotation on
Next and WebUI X) does to a running `flutter run` (it should see a new client
and start the app fresh).

## Fake host

`tool/fake_host/fake_host.mjs` is a fake manager in headless Chromium: it
serves a webroot at `https://mui.kernelsu.org/` (route interception; nothing
listens on a port), injects one host profile's bridge, logs what the page asks
of the host, and exits non-zero when Flutter shows no first frame.

```sh
node tool/fake_host/fake_host.mjs --webroot build/web --host kernelsu \
  [--dark] [--insets 24,48] [--events pause,resume,back] [--screenshot out.png] [--exec-local]
```

Setup, once: `cd tool/fake_host && npm ci` (Playwright 1.56.1, which wants
Chromium build 1194: `npx playwright install chromium` on a new machine). With
no `node_modules` it falls back to a global `playwright` (`npm root -g`), so on
a machine that has one, nothing needs installing; point
`PLAYWRIGHT_BROWSERS_PATH` at its browsers if they live elsewhere.

`--help` lists every option. The ones that matter:

| Option | Meaning |
|---|---|
| `--webroot <dir>` | a `flutter build web` output with the bootstrap (a module's `webroot`) |
| `--host` | `kernelsu`, `next`, `apatch`, `webuix`, `browser` (the `FakeBridge` profiles in `packages/flutter_webui_client/lib/testing.dart`) |
| `--entry <path>` | page to open; `'dev.html?dev=http://127.0.0.1:8080/'` for the dev loop |
| `--dark` | `prefers-color-scheme: dark`, and `$<id>.isDarkMode()` true on `webuix` |
| `--insets T,B` or `T,R,B,L` | safe-area insets in px (default: the profile's) |
| `--manager-colors <hex>` | serve `/internal/colors.css` with this `--background` (the manager's Monet theme); without it, a missing file |
| `--events` | after the first frame, in order: `pause`, `resume`, `back`, `tap[@x:y]` (a click, the viewport centre by default), `system-dark`, `system-light` (`prefers-color-scheme`), `wait<ms>` |
| `--exec-local` | run `ksu.exec` commands with `/bin/sh` here; off by default (exec answers `0, '', ''`) |
| `--csp <policy>` | send a Content-Security-Policy with HTML pages |
| `--screenshot <png>`, `--timeout <s>`, `--hold <s>`, `--viewport WxH` | |

Exit status: 0 first frame seen, 1 none within `--timeout` (or the page
died), 2 bad usage.

Profiles:

| Profile | Globals | insets | Missing files | pause / resume / back |
|---|---|---|---|---|
| `kernelsu` | `ksu` with `enableEdgeToEdge`, `moduleInfo`, `exit` | `/internal/insets.css`, 24/48 | empty 200 | `visibilitychange` hidden / visible; `WebView.goBack()` if `canGoBack()`, else the activity finishes (below) |
| `next` | `ksu` with `enableInsets`, `moduleInfo`, no `exit` | `insets.css`, 24/48 | empty 200 | same |
| `apatch` | `ksu` with `enableInsets`, no `moduleInfo` (id from the meta), no `exit` | none | empty 200 | same |
| `webuix` | `ksu` with `moduleInfo`, `mmrl`; `webui.exit`; `$<id>.isDarkMode()` | variables on `<html>` and `insets.css`, 30/20 | 404 | `WX_ON_PAUSE` / `WX_ON_RESUME` / `WX_ON_BACK` messages (JSON strings) |
| `browser` | none | none | 404 | as `kernelsu`, Back is `history.back()` |

Back on the KernelSU-family profiles follows Chromium's history intervention,
which `WebView.canGoBack()` honours: an entry the page left by `pushState`
without user activation (trusted input in the last 5 s here) is skipped until
the next user activation, and with nothing left the activity would finish.
`kernelsu` answers with `canGoBack()` as of the last history update (KernelSU
reads it in `doUpdateVisitedHistory`), `next` and `apatch` read it at Back.
This reproduces devicelab's results for 020ab92 and 8deba51 on KernelSU 3.3.0
and Next v3.4.0.

Output, one line each: `[bridge]` calls into the host (`ksu.exit()`,
`ksu.enableEdgeToEdge(true)`, `ksu.exec("...")`, `$id.isDarkMode()`),
`[lifecycle]` what the host did and the page's `visibilitychange`,
`[console.<type>]`, `[pageerror]`, `[missing]` files the webroot lacks,
`[requestfailed]`, `[csp]` violations, `[flutter] first frame at N ms`,
`[result] OK` or `FAIL`. Headless Chromium's software-GL warnings are dropped
unless `--verbose`. The fake grants Local Network Access so `dev.html` can
reach `127.0.0.1` (`--deny-local-network` shows the failure).

The counter app (release, dart2js) with `--events pause,resume,back`, all five
profiles: first frame at 670 to 760 ms; `kernelsu` called
`ksu.enableEdgeToEdge(true)` and, on Back at the root route, `ksu.exit()`;
`next` and `apatch` called `ksu.enableInsets(true)` and no exit (as
docs/hosts.md says); `webuix` called `$<id>.isDarkMode()` on start and on
`WX_ON_RESUME` and `webui.exit()` on `WX_ON_BACK`; `browser` left the page on
Back.

### Dev server

```sh
node tool/fake_host/dev_server.mjs --dir build/web --port 8080            # a build
node tool/fake_host/dev_server.mjs --proxy http://127.0.0.1:U --port 8080  # flutter run -d web-server
```

No dependencies. `--origin` changes the allowed origin, `--flutter` names the
SDK for the Roboto fallback, `--no-cors` and `--no-pna` drop headers to see
what breaks. A whole loop on one machine:

```sh
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 8090 --no-web-resources-cdn &
node tool/fake_host/dev_server.mjs --proxy http://127.0.0.1:8090 --port 8085 &
mkdir -p /tmp/devroot && cp bootstrap/dev.html /tmp/devroot/
node tool/fake_host/fake_host.mjs --webroot /tmp/devroot --entry 'dev.html?dev=http://127.0.0.1:8085/' --hold 600
```

## Open (devicelab)

- Whether the device's WebView enforces Local Network Access for the
  manager's page, and how the manager would grant it.
- Hot restart and reload over `adb reverse`, per manager; DDC load time.
- WebUI X's real CSP and how a dev module widens it.
