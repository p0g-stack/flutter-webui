# Parity: IME, clipboard, fonts, locale, accessibility, lifecycle

Embedder comparison for flutter-webui (Flutter 3.47.5 `web_ui` inside a root
manager's Android System WebView). Written 2026-10-01. Nothing here is
device-verified. Every "devicelab" line is something to measure before a
claim goes into `docs/hosts.md`.

**Sources and abbreviations**

- `E/` = Flutter 3.47.5 `engine/src/flutter/lib/web_ui/lib/src/engine/`
- `UW/` = Flutter 3.47.5 `engine/src/flutter/lib/web_ui/lib/ui_web/src/ui_web/`
- `A/` = Flutter 3.47.5 `engine/src/flutter/shell/platform/android/io/flutter/`
- `FP/` = github.com/ardera/flutter-pi `src/` (main, 2026-10-01)
- `KSU/` = github.com/tiann/KernelSU `manager/app/src/main/java/me/weishu/kernelsu/ui/webui/` (commit 08a3b08)
- `NEXT/` = github.com/KernelSU-Next/KernelSU-Next `manager/app/src/main/java/com/rifsxd/ksunext/ui/webui/` (commit 2b31f71)
- `WX/` = github.com/MMRLApp/WebUI-X-Portable (commit ed569e1)
- `CR/` = Chromium `main`, fetched 2026-10-01 from the GitHub mirror
  (raw.githubusercontent.com/chromium/chromium/main/...). `AwContents.java`,
  `aw_permission_manager.cc` (`apm.cc`), `aw_content_browser_client.cc`
  (`acbc.cc`), `aw_settings.cc`, `gfx/browser_view_renderer.cc` (`bvr.cc`),
  `AwDisplayCutoutController.java` (`AwDCC`), `base/.../LocaleUtils.java`.
  These line numbers belong to that snapshot. A device's WebView may be older.
- `AOSP/ClipboardService.java` = aosp-mirror/platform_frameworks_base `main`
  (the mirror may lag AOSP).

**Host WebView setup (applies to every section)**

| | KernelSU | KernelSU-Next | WebUI X Portable |
|---|---|---|---|
| Settings | JS, DOM storage, no file access (KSU/WebViewHelper.kt:85-89) | same (NEXT/WebUIActivity.kt:216-218) | JS, DOM storage (WX/hwui/.../HybridWebUI.kt:164-166); mixed content only in debug+remote (WX/webui/.../view/WXView.kt:86-88) |
| User agent | default WebView UA (no override found by grep) | default | **custom**: `WebUI X/<v> (Linux; Android <rel>; <model>; <platform>/<ver>)` (WX/app/.../webui/WebUIActivity.kt:51-65, set at WXView.kt:89). It has `Android` but no `Chrome/` and no `wv` |
| `onPermissionRequest` | not overridden (KSU/WebViewHelper.kt:149-187) | not overridden (NEXT/WebUIActivity.kt:225-272) | grants only `android.webkit.resource.*` listed in config.json, after a dialog (WX/webui/.../client/WXChromeClient.kt:84-104) |
| Soft input | `SOFT_INPUT_ADJUST_NOTHING` + Compose `imePadding` on the WebView box (KSU/WebUIActivity.kt:41; KSU/WebUIScreen.kt:56-59,87) | not set; container listener reads only `systemBars()` and returns `CONSUMED` (NEXT/WebUIActivity.kt:194-214) | global-layout listener resizes the WebView height (`windowResize`, default true) (WX/webui/.../activity/WXActivity.kt:152-207; Config.kt:408) |
| Config changes | handled in place, locale and fontScale included (KSU manifest line 69) | recreate (no `configChanges`, NEXT manifest 60-65) | recreate |
| Pause | `webView.onPause()/onResume()` on ON_PAUSE/ON_RESUME (KSU/WebUIScreen.kt:136-154) | **never** calls `webView.onPause()` (NEXT/WebUIActivity.kt:462-520) | `onPause()` + `pauseTimers()` + `WX_ON_PAUSE` (WXActivity.kt:309-330) |
| Bridge for locale, a11y, clipboard, keyboard | none (KSU/WebViewInterface.kt methods: exec, spawn, toast, fullScreen, enableEdgeToEdge, moduleInfo, listPackages, getPackagesInfo, exit) | none (also file I/O and packages, no exit) | `WX_ON_KEYBOARD` only. No clipboard method (grep over all `.kt`) |

`web_ui` decides "Android" from `navigator.userAgent.contains('Android')`
(UW/browser_detection.dart:166-170) and "Blink" from `navigator.vendor ==
'Google Inc.'` (UW/browser_detection.dart:107-108). All three hosts therefore
look like Android Chrome to `web_ui` (mobile, Blink), including WebUI X with its
custom UA. `isChrome110OrOlder` reads `Chrome/NN` from the UA
(E/browser_detection.dart:59-72), so under WebUI X it returns false, which is the
right answer for a current WebView.

---

## 1. Text input and IME

| | web_ui (browser) | Android embedder | flutter-pi | Manager WebView |
|---|---|---|---|---|
| Editing element | Hidden DOM `<input>`/`<textarea>`. Strategy chosen by OS: iOS, then Android → `AndroidTextEditingStrategy`, then Safari, Firefox, default (E/text_editing/text_editing.dart:2217-2230). With semantics on, it uses `SemanticsTextEditingStrategy` instead (2600-2604) | `TextInputPlugin` + `InputConnectionAdaptor` (A/plugin/editing/InputConnectionAdaptor.java:43) | Physical keyboard only. `TextInput.show` does nothing (FP/plugins/text_input.c:393-406) | UA contains `Android`, so the Android strategy runs, the same as Chrome on Android |
| Composition | DOM composition events (`addCompositionEventHandlers`, text_editing.dart:2075; E/text_editing/composition_aware_mixin.dart) | `setComposingRegion`/composing text through the IME (InputConnectionAdaptor.java:145-148,196) | Stores composing base/extent from the framework (text_input.c:365-385). No IME | Same Blink IME adapter as Chrome, so the same events (inferred) |
| Autofill | `<form>` with `autocomplete` hints (E/text_editing/autofill_hint.dart; `placeForm`, text_editing.dart:2036-2038) | `AutofillManager` (A/plugin/editing/TextInputPlugin.java:84) | `requestAutofill` is a no-op (text_input.c:409) | WebView sets `uses_platform_autofill = true` (CR/aw_settings.cc:330-333), so Android's autofill service is used, not Chrome's (inferred from the source) |
| Keyboard inset | Listens to `visualViewport` `resize`, else `window` (E/view_embedder/dimensions_provider/full_page_dimensions_provider.dart:26-35). While editing on mobile it keeps the old `physicalSize` and reports `viewInsets.bottom = physicalHeight − visualViewport.height` (E/window.dart:297,311-319; full_page_dimensions_provider.dart:97-114). Our patch 0004 lets `setHostKeyboardInset` replace that value | `WindowInsets.Type.ime()` → `viewInsetBottom` (A/embedding/android/FlutterView.java:758-761). Before API 30 it guesses from system window insets (702-714, 821) | none | KSU: the WebView shrinks (Compose IME padding, animated per frame). WX: the WebView height is set once per show/hide. Next: no IME handling; see the gap below. Current Chromium WebView also insets the *visual* viewport by the IME overlap when the WebView itself is not resized (CR/AwDCC:191-209,243-278), but only if the WebView receives IME insets |
| Scroll focused field into view | Framework (`EditableText` shows the caret on screen after `viewInsets` changes). `scrollIntoViewIfEmbedded` only in embedded mode (text_editing.dart:1419-1421) | framework | framework | Same as web_ui. It depends on `viewInsets` being right |

WebUI X `WX_ON_KEYBOARD` payload: `{height: Int, visible: Boolean}`
(WX/webui/.../model/Event.kt:37-48). `height = rootView.height −
visibleDisplayFrame.bottom` converted to dp (`asPx` divides by density,
WXActivity.kt:367-368). It is sent **only when visibility flips**, with a 15%
screen heuristic (WXActivity.kt:157-171), so a height change (emoji panel,
suggestion strip) is not reported. When `windowResize` is true (the default),
WebUI X also resizes the WebView (WXActivity.kt:185-207), so `web_ui`'s own
resize path already sees the keyboard.

**Gap**

- KernelSU and WebUI X: the WebView is resized, so `web_ui`'s existing path works
  (the layout and visual viewports shrink together, and `_shouldPreservePhysicalSizeOnResize`
  turns that into `viewInsets`). One difference from Chrome: KernelSU's Compose
  IME padding animates, which likely sends one `resize` per animation frame and
  one Flutter relayout each (inferred).
- KernelSU-Next: the activity is edge-to-edge (`enableEdgeToEdge()`), sets no
  soft-input mode and consumes insets on the WebView's parent without reading
  `ime()`. On API 30+ with edge-to-edge, the system does not resize the window
  for the IME (inferred, Android docs). The WebView's own IME→visual-viewport
  code (CR/AwDCC) only runs if the WebView receives the IME insets, and the
  parent returns `CONSUMED`. **Likely outcome: the keyboard covers the page,
  `viewInsets` stays 0 and the focused field is hidden.** Inferred; this needs a
  device check first. `docs/hosts.md` currently says "the WebView resizes" for
  every host. That row is unverified for Next.
- WebUI X with `windowResize: false`: only a CSS variable
  `--window-keyboard-height` is set (WXActivity.kt:216-221), and `web_ui` does
  not see the keyboard. Our `config.json` template does not set
  `windowResize`, so the default (true) applies. Keep it that way.

**Recommendation (smallest)**

1. No new engine code for KernelSU or WebUI X. Keep not wiring `WX_ON_KEYBOARD`.
   It is toggle-only and would double-count with the resize.
2. Add `"windowResize": true` explicitly to flutter_p0g's WebUI X `config.json`
   template, so that a module author cannot lose it by accident.
3. Next: measure first. If the gap is confirmed, the right fix is upstream in
   KernelSU-Next (read `Type.ime()` in its insets listener, as KernelSU does), and
   we record it in `hosts.md`. A local workaround with `setHostKeyboardInset`
   would need the IME height. The WebView exposes no IME height without a
   resize, and a root query (`dumpsys input_method` / `dumpsys window`) would be
   polling. Do not build that unless the device check shows the gap and upstream
   will not take a fix.

**Devicelab checks**

- Per host: focus a `TextField` near the bottom. Log `innerHeight`,
  `visualViewport.height`, `MediaQuery.viewInsets.bottom` and the caret
  visibility. Expect: KSU/WX inset > 0; Next to be determined.
- KSU: count `visualViewport` `resize` events during the IME show animation, and
  check the frame time.
- Next: also log `'virtualKeyboard' in navigator` and whether `visualViewport.height`
  changes. This tells whether the device's WebView applies the AwDCC IME inset.
- Composition: type CJK (pinyin) and a Gboard swipe word. Check that the composing
  underline and commit are correct.
- Autofill: a username/password form. Does the Android autofill service offer
  suggestions?

---

## 2. Clipboard (KernelSU family, no host API)

| | web_ui (browser) | Android embedder | flutter-pi | Manager WebView |
|---|---|---|---|---|
| Write | `navigator.clipboard.writeText` (E/clipboard.dart:102-104). Patch 0005 swaps in the host's `HostClipboard` when one is set | `ClipboardManager.setPrimaryClip` (A/plugin/platform/PlatformPlugin.java:145-146). Writing is allowed without focus (AOSP/ClipboardService.java:1383-1386) | `Clipboard.setData` falls through to `not_implemented` (FP/plugins/services.c:56-61, 226) | Async write ("sanitized write") is **auto-granted** (CR/apm.cc:379-391, 559-566). `execCommand('copy')` needs a user gesture, because WebView exposes no "JS can access clipboard" setting (CR/aw_settings.cc has no clipboard pref; inferred) |
| Read | `navigator.clipboard.readText` (E/clipboard.dart:107-109). `hasStrings` also calls `readText` (59-73) | `getPrimaryClip` + coerce a URI to text (PlatformPlugin.java:627-690). The app is focused, so the read is allowed (ClipboardService.java:1346-1356) | not implemented | **Always denied.** `CLIPBOARD_READ_WRITE` is `NOTIMPLEMENTED` → `DENIED` in `RequestPermissions` (CR/apm.cc:384-387, 397, 420-424) and `DENIED` in the status lookup (apm.cc:580-603). It is never forwarded to `onPermissionRequest`, so WebUI X's handler cannot grant it either. `execCommand('paste')` needs DOM paste, which WebView does not enable (inferred) |
| Paste in text fields | On web the framework uses the browser context menu (`BrowserContextMenu.enabled` defaults to true: packages/flutter/lib/src/services/browser_context_menu.dart:39; editable_text.dart:2541). Native paste lands in the DOM input with no permission needed | framework toolbar | n/a | WebView's own selection action mode on the hidden input (inferred). A user paste works. Only **programmatic** `Clipboard.getData` fails |

Our code: `BrowserClipboard`
(`packages/flutter_webui/lib/src/web/engine_hooks.dart:67-95`). Write tries
`writeText` and falls back to `execCommand('copy')`. Read tries `readText` and
throws `StateError`. That surfaces as a `paste_fail`/`has_strings_fail` error
envelope (E/clipboard.dart:49-54, 67-72). If `BrowserContextMenu` is disabled,
the framework's `ClipboardStatusNotifier` catches it and reports `unknown`
(packages/flutter/lib/src/widgets/text_selection.dart:3805-3823). The behaviour
is the same as Firefox, which has no `readText`.

**Root-side fallback (question → answer from source)**

- AOSP has no `cmd clipboard`: `ClipboardService` has no shell command (grep
  `onShellCommand` → none in AOSP/ClipboardService.java). `service call
  clipboard N` depends on transaction numbers and parcel layout that change
  between releases (fragile, inferred).
- Android 10+ background read rule: a read needs the default IME, a focused uid,
  or `READ_CLIPBOARD_IN_BACKGROUND` ("Shell can access the clipboard for testing
  purposes", ClipboardService.java:1337-1344). `checkPackage(uid,
  callingPackage)` runs first (1329), so a root process must run **as the shell
  uid (2000)** with package `com.android.shell`. It calls `IClipboard` through an
  `app_process` helper dex, the way scrcpy's server does (inferred precedent).
  Writes need no focus (1383-1386). Android 12+ may show a "pasted from your
  clipboard" toast naming Shell (inferred).

**Gap.** Programmatic read (`Clipboard.getData`, and `hasStrings` when the
framework toolbar is used) fails on every manager. In a Chrome tab it works
after a permission prompt. Write and user-initiated paste reach parity
(inferred, verify).

**Recommendation (smallest)**

1. flutter-webui: no engine change. Patch 0005's `setHostClipboard` hook is the
   seam. Keep `BrowserClipboard` as is. Optionally drop the `execCommand('copy')`
   fallback once devicelab confirms that `writeText` works on all hosts, since
   WebView auto-grants it.
2. The read fallback is a **plugin** (webui-packages clipboard): a
   `TextClipboard` backed by the root channel. It launches a tiny `app_process`
   helper as uid 2000 (`su 2000` / `su -s ... shell`) that calls
   `IClipboard.getPrimaryClip("com.android.shell", ...)`, and installs it through
   `setClipboard`. This is not the root channel's job (AGENTS.md: "a feature on
   top lives with its owner").
3. Do not use `service call clipboard`.

**Devicelab checks.** Per host and Android version: `writeText` inside a tap
handler resolves. `readText` rejects with `NotAllowedError`. Long-press paste
in a `TextField` works. Root helper read as uid 2000 on Android 10, 13 and 15:
does it succeed, and does it show a toast? Does a read while the manager is
focused interact with the manager's own focus check?

---

## 3. Fonts and emoji fallback, offline

| | web_ui (browser) | Android embedder | flutter-pi | Manager WebView |
|---|---|---|---|---|
| Font source | Only fonts loaded as bytes: `FontManifest.json` assets (E/initialization.dart:224; E/canvaskit/fonts.dart:115-135) and downloaded fallbacks. CanvasKit uses a `TypefaceFontProvider` over FreeType faces made from data (canvaskit/fonts.dart:73, 95, 154). No system or local fonts | Skia `SkFontMgr_New_Android` over `/system/fonts` (engine `txt/src/txt/platform_android.cc:22-29`) | Skia fontconfig font manager (`txt/src/txt/platform_linux.cc:27-35`). The README requires installing system fonts (flutter-pi README.md:72-92) | Same as web_ui. Local Font Access (`queryLocalFonts`) is DENIED in WebView (CR/apm.cc:580-603, `LOCAL_FONTS`). **Confirmed: the WebView does not expose system fonts to CanvasKit/Skwasm** |
| Default font | Roboto from `${fontFallbackBaseUrl}roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2` when the manifest has no Roboto (canvaskit/fonts.dart:17-18, 119-135; skwasm/skwasm_impl/font_collection.dart:20-21, 86-88) | system Roboto | system default | needs the bundled file |
| Fallback | 724 `NotoFont(name, url)` entries in 112 families (E/font_fallback_data.dart). URL = `Uri.parse(fontFallbackBaseUrl).resolve(font.url)` (E/font_fallback_service.dart:491-494). Default base `https://fonts.gstatic.com/s/` (E/configuration.dart:366-368). 3 retries, 1 s apart; a 4xx or unparsable data is permanent; after 10 failures with no success the service turns itself off (font_fallback_service.dart:57-68, 485-584) | system fallback chain (NotoColorEmoji, CJK) | fontconfig | Our bootstrap sets `fontFallbackBaseUrl: 'fonts/'` (bootstrap/flutter_bootstrap.js:13), resolved against `<base href="/">` → `https://mui.kernelsu.org/fonts/<family>/v<N>/<file>.woff2`. KernelSU-family hosts answer a missing file with an empty 200 (hosts.md). `hasPayload` is true for 2xx (E/dom.dart:1333-1336), then parsing fails, which counts as a permanent failure. Nothing breaks, the glyphs are just missing (tofu) |
| CJK choice | locale-ranked: zh-Hant/TW/MO → TC, HK → HK, ja → JP, ko → KR, zh/zh-Hans/zh-CN → SC (font_fallback_service.dart:350-372, 423-432) | system | system | follows `navigator.languages` (see 4) |

File naming: the paths are the gstatic paths, e.g.
`notocoloremoji/v32/Yq6P-KqIXTD0t4D9z1ESnKM3-HpFabsE4tq3luCC7p-aXxcn.0.woff2`
(font_fallback_data.dart:10-13). Large families are split into numbered slices
`.<n>.woff2`. A build step copies `fonts.gstatic.com/s/<path>` to
`webroot/fonts/<path>` byte for byte. The list is derived from
`font_fallback_data.dart` at the pinned Flutter version and changes when Flutter
rolls `dev/roll_fallback_fonts.dart`.

Size budget (HEAD `content-length` from fonts.gstatic.com, 2026-10-01, all 725
files including Roboto):

| Set | Files | Size |
|---|---|---|
| Noto Color Emoji | 12 | 1.92 MiB |
| Symbols (Noto Sans Symbols, Symbols 2) | 7 | 0.48 MiB |
| Roboto | 1 | 0.06 MiB |
| CJK (SC, TC, HK, JP, KR) | 563 | 11.79 MiB |
| Other scripts (Arabic, Devanagari, Thai, Hebrew, ...) | 142 | 6.54 MiB |
| **Total** | 725 | **20.8 MiB** |

A symlink from webroot to `/system/fonts` is not an option: KernelSU's
`SuFilePathHandler` only serves canonical children of webroot
(KSU/SuFilePathHandler.java:109-120). The WebUI X CSP has `default-src 'self'`
and `connect-src *` (WX/webui/.../model/Config.kt:421-423), so same-origin font
fetches are allowed.

Renderer: the bootstrap forces single-threaded Skwasm. CanvasKit is the
fallback. Both use the same `fontFallbackBaseUrl` and the same Roboto path.
Font handling does not depend on the renderer.

**Gap.** Offline, or on WebUI X with gstatic blocked, the page has no Roboto
unless it is bundled and no emoji or other scripts. A browser tab online
downloads them on demand.

**Done here.** `web_ui/tool/fallback_fonts.dart` reads the list from the
pinned sources and copies the files into `<webroot>/fonts/` through a download
cache: default set (Noto Sans, emoji, Symbols, Symbols 2, Math, Roboto; 2.9
MiB), `--locales` for CJK, `--all` for everything. Checked in Chromium with
every non-module request blocked: a release build with the default set renders
emoji and symbols, and requests only bundled files; without it they are tofu.
Flutter 3.47.5 builds also ship `assets/fonts/fallback/Roboto-Regular.ttf` in
the font manifest, so the bundled Roboto is only used when that is missing.
A page whose `navigator.languages` is empty fails to start in `web_ui`
(`Incorrect locale information provided`); WebView always lists en-US, so
this only affects test harnesses.

**Recommendation (smallest)**

- **flutter_p0g build step** `fonts` (runs `web_ui/tool/fallback_fonts.dart`): generate the list from the pinned
  `font_fallback_data.dart` plus the Roboto URL, fetch from gstatic into a
  cache (`precache`), and copy into `webroot/fonts/`. Default set: Roboto, emoji
  and symbols (about 2.5 MiB). CJK by the app's `supportedLocales`, using the
  same mapping as `_kLanguageFontPreferences` (e.g. `ja` → JP, about 2.3 MiB
  each). `--fallback-fonts=all` adds the other scripts (20.8 MiB in total). Check
  each file's hash against the cache.
- No web_ui patch: `fontFallbackBaseUrl` is already the hook.
- Optional: drop the 10-failures kill switch? No. It is web_ui's behaviour, and
  with a bundled set it will not trigger.

**Devicelab checks.** In airplane mode, render a page with Latin, emoji and the
app's CJK locale text: no tofu, and no gstatic request in the WebView netlog or
devtools. Check the time to first emoji glyph. Measure the module zip size per
set.

---

## 4. Locale

| | web_ui (browser) | Android embedder | flutter-pi | Manager WebView |
|---|---|---|---|---|
| Source | `navigator.languages` → `ui.Locale` list. `locale` is the first entry (E/platform_dispatcher.dart:838-855, 946-969) | `Configuration.getLocales()` (A/plugin/localization/LocalizationPlugin.java:142-152) | env `LANGUAGE` > `LC_ALL` > `LC_MESSAGES` > `LANG` (FP/locales.c:41-64) | `navigator.languages` = Accept-Language = `LocaleList.getDefault()` of the **manager process**, with `en-US` appended if missing (CR/acbc.cc:249-258; CR/LocaleUtils.java:189-194; CR/aw_settings.cc:325-328) |
| Updates | `languagechange` listener (platform_dispatcher.dart:860-876) | at start (A/embedding/engine/FlutterEngine.java:423) and `onConfigurationChanged` (FlutterView.java:490) | once at start (locales.c:393-400; flutter-pi.c:1429) | `updateDefaultLocale` at init, on attach and on `onConfigurationChanged` (CR/AwContents.java:927-929, 1134, 1681-1692). A `languagechange` follows (inferred). KSU handles `locale` itself, so in place. Next and WX recreate, so the page reloads |

Per-app language: KernelSU enables `generateLocaleConfig` (KernelSU
manager/app/build.gradle.kts:133), and Next uses the framework `LocaleManager`
on Android 13+ (NEXT/../util/LocaleHelper.kt:48-56). With a framework per-app
locale, the app process's default locale list is the per-app one (inferred,
platform behaviour), so `navigator.languages` follows the manager's language.
On Next before Android 13 the choice is applied only through
`createConfigurationContext` in `MainActivity.attachBaseContext`
(LocaleHelper.kt:58-77; MainActivity.kt:214-215). That does not change
`LocaleList.getDefault()`, so the WebView reports the **system** locale there
(inferred). `getprop persist.sys.locale` gives only the first system locale. It
ignores per-app choices and is not what a browser reports. There is no ksu
bridge for the locale.

**Gap.** In effect none. A browser tab reports the browser's language list, and
here the "browser" is the manager. `navigator.languages` is the right parity
source. The trailing `en-US` is Chromium WebView's behaviour, too.

**Recommendation.** No fix. Do not add a root `getprop` path, which would be
less faithful than the WebView. Document it in `hosts.md`: "Locale = manager's
locale list (per-app language on Android 13+), plus en-US."

**Devicelab checks.** Log `navigator.languages` and `PlatformDispatcher.locales`
with system language X and manager per-app language Y (Android 13+). Change the
system language while the page is open: KSU should fire `languagechange` and
update in place, Next and WX should reload.

---

## 5. Accessibility

| | web_ui (browser) | Android embedder | flutter-pi | Manager WebView |
|---|---|---|---|---|
| Enabling | Off until asked. Mobile → `MobileSemanticsEnabler`, desktop → `DesktopSemanticsEnabler` (E/semantics/semantics_helper.dart:39-41). Mobile: a full-view `flt-semantics-placeholder role=button`, labelled `ui_web.accessibilityPlaceholderMessage` ("Enable accessibility", UW/semantics.dart:7-15). A click within 1 px of its centre (what TalkBack's double-tap produces) enables semantics after 300 ms. After 20 non-matching events it gives up (semantics_helper.dart:18,25, 323-376, 389-414) | Auto: `AccessibilityStateChangeListener` → `onAndroidAccessibilityEnabled` (A/view/AccessibilityBridge.java:395-413), `accessibleNavigation` from touch exploration (552-578), `setSemanticsEnabled` (FlutterView.java:164) | none: semantics callbacks are NULL (FP/flutter-pi.c:1351-1352) | TalkBack reads the WebView's DOM accessibility tree, the same mechanism as Chrome (inferred). UA has `Android` → mobile enabler, so the same placeholder as Chrome on Android |
| Programmatic | The first framework semantics update auto-enables engine semantics and removes the placeholder (E/semantics/semantics.dart:2869-2883). The framework's `SemanticsBinding.ensureSemantics()` causes that | n/a | n/a | same as web_ui |

**Gap.** Compared with a browser tab: none. Chrome on Android has the same
placeholder flow. Compared with Android: TalkBack users must find and activate
"Enable accessibility" once per page load. The pause pattern makes this
noticeable, because Next and WX reload on every configuration change. No bridge
reports the screen reader state. Root can read it: `settings get secure
touch_exploration_enabled` (what the Android embedder keys `accessibleNavigation`
on) or `accessibility_enabled` plus `enabled_accessibility_services`.

**Recommendation (smallest)**

- No web_ui patch: the existing auto-enable on the first update is the seam.
- Optional plugin feature (flutter_webui or webui-packages, opt-in): at start,
  read `touch_exploration_enabled` through the root channel (or one `ksu.exec`).
  If it is 1, call `SemanticsBinding.instance.ensureSemantics()` and keep the
  handle. Re-check on resume. This goes beyond browser parity, so ship it off by
  default or behind a flag, and say so in `hosts.md`.
- Localise `ui_web.accessibilityPlaceholderMessage` from the app (already a
  public API). Nothing for this repo.

**Devicelab checks.** With TalkBack on, per host: is the placeholder announced,
does double-tap enable semantics, and can a button be activated afterwards?
Explore-by-touch over Flutter widgets. Text field editing under the semantics
strategy, including IME.

---

## 6. Lifecycle without pause events (KernelSU family)

| | web_ui (browser) | Android embedder | flutter-pi | Manager WebView |
|---|---|---|---|---|
| Signals | window `focus` → resumed, `blur` → inactive, `visibilitychange` → resumed/hidden, no views → detached (E/platform_dispatcher/app_lifecycle_state.dart:72-74, 91-113). Patch 0002 lets the host override it | `LifecycleChannel`: onResume → resumed, onPause → inactive, onStop → paused, detach → detached (A/embedding/android/FlutterActivityAndFragmentDelegate.java:604, 653, 676, 806) | none sent (no "lifecycle" in FP/) | Page visibility = `!paused && (!was_attached || (attached && window_visible))` (CR/bvr.cc:561-569). `WebView.onPause()` sets paused and updates visibility (CR/AwContents.java:3063-3082, 3884-3895). Window visibility comes from `onWindowVisibilityChanged` (AwContents.java:3795-3802, 5074) |

Per host (from the sources above):

- **KernelSU**: `webView.onPause()` on ON_PAUSE → `visibilitychange` hidden →
  `AppLifecycleState.hidden`. This also fires when another activity covers the
  page, e.g. its own file chooser or a permission dialog. In a browser tab that
  case is `blur` → inactive. A small difference, and harmless in practice
  (inferred). No `pauseTimers()`.
- **KernelSU-Next**: no `onPause()`. Going Home stops the activity, the window
  becomes invisible, and `window_visible_` turns false → hidden (inferred from
  bvr.cc). Rotation or dark mode recreates the activity, which reloads the page.
  The biometric lock overlay (`lockOverlay`, NEXT/WebUIActivity.kt:462-506) is a
  view, not a pause, so the page stays visible under it.
- **WebUI X**: `onPause()` + `pauseTimers()` + `WX_ON_PAUSE`. By the Chromium
  source, `onPause()` alone makes `visibilityState` hidden, which **contradicts
  hosts.md** ("`visibilityState` stays `visible`"). Measure, then fix whichever
  is wrong. `pauseTimers()` → `setWebKitSharedTimersSuspended(true)`
  (AwContents.java:3043-3048) is process-wide. WebUI X runs its WebUI activity
  in its own process (WX/app/src/main/AndroidManifest.xml, `android:process`), so
  this is contained.
- Throttling: a hidden page gets Blink's hidden-page timer throttling and no
  `requestAnimationFrame`, the same as a background tab (inferred). This matches
  AGENTS.md "never rely on page timers while hidden".

**Gap.** Probably none for KSU and Next: `visibilitychange` should fire, which
is what a browser tab does. WebUI X has `WX_ON_PAUSE` already wired to `hidden`
via patch 0002. Mapping is redundant if `visibilitychange` also fires, but
harmless.

**Recommendation.** No code. Resolve the open `hosts.md` items with devicelab
and correct the WebUI X row if the source holds.

**Devicelab checks.** Per host, log `document.visibilityState`,
`visibilitychange`, `focus` and `blur` with timestamps for: Home and back,
recents, screen off, the file chooser, rotation (Next and WX reload),
notification shade (expect no change, or `blur` only). Measure the
`setTimeout(…,1000)` cadence while hidden on KSU (not paused) against WX (paused).

---

## Summary of recommended changes

| Topic | Layer | Change |
|---|---|---|
| IME | flutter_p0g template | add `"windowResize": true` to WebUI X `config.json` |
| IME | devicelab, hosts.md | KernelSU-Next keyboard inset (likely broken upstream); the KSU per-frame resize cost |
| Clipboard | plugin (webui-packages) | root-backed `TextClipboard` read via an `app_process` helper as uid 2000, installed through `setHostClipboard`; no engine change |
| Fonts | flutter_p0g build step | bundle `webroot/fonts/` from gstatic at the pinned list: Roboto, emoji and symbols by default (~2.5 MiB), CJK by supportedLocales, `all` = 20.8 MiB |
| Locale | none | document only |
| A11y | optional plugin, opt-in | `touch_exploration_enabled` via root → `ensureSemantics()` |
| Lifecycle | hosts.md | verify and fix the WebUI X `visibilityState` claim |
