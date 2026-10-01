# flutter-webui: working agreements

Self-contained; no external base file.

- Pattern first. Before designing a feature, check how `web_ui` (our peer) and
  other embedders handle it, and scope ours to that.
- Parity means a Flutter web app in a browser tab, not Android.
- If Flutter has a concept for it on web, it is this repo's job. If it doesn't,
  it belongs in a plugin (`webui-packages`) or in the app.
- Detection probes optional host methods. A manager's name or version never
  selects behaviour. A new manager is a detection change plus a row in
  `docs/hosts.md`.
- The root channel stays a channel: transport and process launch only. A
  feature on top lives with its owner (handler, plugin, app).
- Every string that reaches `ksu.exec` / `ksu.spawn` is quoted here, not by the
  caller.
- Hidden keeps running, closed stops. Ship WebUI X `config.json` with
  `killShellWhenBackground: false`; never rely on page timers while hidden.
- Host claims and numbers (freeze times, latency) come from devicelab runs,
  with the device and manager named. Tests are unit tests against fakes.
- `web_ui/patches` is a `git format-patch` series against the Flutter release
  tag in `web_ui/VERSION`. Edit it as commits on that tag, never by hand, and
  rebuild with `web_ui/tool/build_web_sdk.dart` to check it compiles.
- Never pause a `dart:io` process stdout/stderr subscription in the root
  channel: on Dart 3.13.4 a resumed pipe can miss its wake-up and stall the
  child for good.
- The root channel runs on Android under a glibc runtime, where resolving
  outside hostnames fails. Use IP literals only (it binds `127.0.0.1`), and
  ship `dartaotruntime` plus a `.aot` snapshot, never a `dart compile exe`
  binary (it cannot run through the bundled loader).
