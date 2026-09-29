# flutter-webui: working agreements

Extends `~/.agents/AGENTS.md`. Seed; refine per directory as the nest fills in.

- If stock Dart should do it on this host, it is this repo's job. If Flutter
  has no concept of it, it belongs in `surfaces`.
- Detection probes optional host methods. A manager's name or version never
  selects behaviour.
- Every string that reaches `ksu.exec` is quoted here, not by the caller.
- Numbers quoted in a PR (freeze times, exec latency) come from the fake-host
  e2e run in that PR's CI, with the profile named.
- A new manager is a detection change plus a row in `spec/host.md`, nothing more.
