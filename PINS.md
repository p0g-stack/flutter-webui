# Pins

Pins: what this repo holds fixed, where, and who moves it. Values read from the repo at the commit that added this file; the bump order across repos is /mnt/project-files/proposals/flutter-bump-checklist.md (project files).

| What | Where | Current | Bumped by |
| --- | --- | --- | --- |
| Flutter release the web_ui patches apply to | `web_ui/VERSION` | 3.47.5 | flutter-webui, with `web_ui/patches` rebased |
| Engine commit | not stored: read from that Flutter release (`bin/internal/engine.version`) and written into the release tag and `manifest.json` | inferred: `af7e796` for 3.47.5 (flutter-aera `spec/engine-pin.md`) | follows VERSION |
| Flutter used by CI | `.github/workflows/ci.yaml` `flutter-version` | 3.47.5 | flutter-webui, same commit as VERSION |

Produces: the patched web SDK release, `web-sdk-<flutter>-<engine:7>-<this repo:7>` (`flutter-webui-web-sdk.tar.xz` + `.sha256` + `manifest.json`), by `.github/workflows/web-sdk-release.yaml` on pushes touching `web_ui/`. Reproducible tarball: same pins, same sha256.
Consumers pin this repo by commit: flutter_p0g `kFlutterWebuiCommit`, bricks' p0g_app, webui-packages (each repo's PINS.md has the current value).
Minimums: the cgroup fix needs `a455782` (channel 0.2.3); WebUI X v608 Back and the fast `shell-refused` error need the commit that added this line, together with flutter_p0g's `webroot/config.json` carrying `"permissions": ["kernelsu.permission.SHELL"]` and `"backInterceptor": "native"`.
Hosts the WebUI X notes in docs/hosts.md were read against: WebUI X Portable v438 (devicelab) and v608 (Play APK sha256 `ae88a8cad10b7d7d2146e9b02726fe588595691ae1d9e95206e0c293deb2afb2`, by bytecode; not yet run).
