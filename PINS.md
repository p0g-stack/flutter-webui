# Pins

Pins: what this repo holds fixed, where, and who moves it. Values read from the repo at the commit that added this file; the bump order across repos is https://github.com/p0g-stack/.github/blob/main/docs/flutter-bump.md.

| What | Where | Current | Bumped by |
| --- | --- | --- | --- |
| Flutter release the web_ui patches apply to | `web_ui/VERSION` | 3.50.0 | flutter-webui, with `web_ui/patches` rebased |
| Engine commit | not stored: read from that Flutter release (`bin/internal/engine.version`) and written into the release tag and `manifest.json` | `371f772` for 3.50.0 (its `bin/internal/engine.version`) | follows VERSION |
| Flutter used by CI | `.github/workflows/ci.yaml` `flutter-version` | 3.50.0 | flutter-webui, same commit as VERSION |

Produces: the patched web SDK release, `web-sdk-<flutter>-<engine:7>-<this repo:7>` (`flutter-webui-web-sdk.tar.xz` + `.sha256` + `manifest.json`), by `.github/workflows/web-sdk-release.yaml` on pushes touching `web_ui/`. Reproducible tarball: same pins, same sha256.
Consumers pin this repo by commit: flutter_p0g `kFlutterWebuiCommit`, bricks' p0g_app, webui-packages (each repo's PINS.md has the current value).
WebUI X target: latest stable only, now v660 official (SHA256
`e7357bcb1dc607a2d1a8de80997d2aae79d3d1453d1c2dce9ebcf6fe000c3787`).
v438 and v608 are retired. Modules declare SHELL and PM permissions and use
`backInterceptor: native`. KernelSU's direct package APIs remain supported.
The WebUI X v660 host migration changed no `web_ui` patches; the rows above
carry the current 3.50.0 web SDK release identity.
