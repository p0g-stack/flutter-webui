# Root channel: contract (v1)

The root channel is `flutter_webui_root` (`packages/flutter_webui_root`), a
Dart program started once by the page through the manager's bridge. It runs as
root, serves one WebSocket on 127.0.0.1, and does three things: launch root
processes and stream their output, carry stdin to them, and read small files
from the module directory. Job stores, file APIs and plugins are built on top
by their owners. An app's own root process (`squadron_process` serve mode; launch contract
owned by `bricks`, generic launcher rules in `squadron_process`
`docs/launchers.md`) is started through it as a detached process.

Status: **v1**. Additive changes only (new optional fields, new ops); anything
else bumps `protocol`.

## Files in the module

```
<moddir>/flutter_webui/
  root                       POSIX sh launcher (packages/flutter_webui_root/module/root)
  <abi>/flutter_webui_root.aot   AOT snapshot of bin/flutter_webui_root.dart
  <abi>/dartaotruntime       Dart AOT runtime that runs on Android
  <abi>/ld-linux-*.so.*, lib*.so.*   only for a linux (glibc) runtime: its loader and libc
<moddir>/tmp/                0700, the channel's TMPDIR (set by the launcher; root
                             shells may start with an empty environment)
<moddir>/webroot/.run/         0711: traversable, not listable
  session.json               0644, written by the channel (below)
  root.log                   0600, channel stderr, truncated on each start
  lock                       0600, held while a channel runs
  proc/                      0700
  proc/<stamp>.log, .exit    0600, output and exit code of detached processes (16 newest kept)
  proc/.boot                 boot id the files in proc/ are from
```

Modes are set explicitly (`chmod`), not left to the umask of whatever shell
started the channel; the channel never changes its own umask, so processes it
starts keep the one they inherit. `session.json` carries the token, so it is
written to a temporary file whose mode is set before the token is written,
then renamed into place.

Why `session.json` is 0644 and `.run/` 0711 rather than root-only: the page
reads `session.json` through the manager's file server, not through root. The
manager source reads (`docs/hosts.md`) say every host serves `webroot/` with
root reads, and `/data/adb` is root-only, which would allow 0600 and 0700. That
is not device-verified yet, so the file stays readable by the uid that serves
it (an open devicelab item in `docs/hosts.md`); once verified, both tighten
without a protocol change. Nothing else in `.run/` is meant for the manager.

On start (after taking `lock`) the channel replaces whatever `session.json`
holds: a file naming a dead pid, another boot (`/proc/sys/kernel/random/boot_id`)
or another version is stale, and with the lock held no other channel of this
module is running. It removes `session.json.*.tmp` left by a killed channel,
and if `proc/.boot` names another boot, every log and exit file in `proc/`
(their processes cannot be running). On exit it removes `session.json` only if
the file still names its own pid.

`<abi>` is `arm64-v8a` or `x86_64`. `flutter_p0g` compiles the snapshot and
ships the runtime: stock `dart compile exe` has no Android target. Either an
Android-built `dartaotruntime` (being proven in devicelab), or the SDK's linux
`dartaotruntime` with the glibc loader and libc/libm/libdl/libpthread next to
it (runs on a Linux host with the system libraries hidden; not yet tried on a
device). The launcher picks the loader when one is present.

## Discovery: `webroot/.run/session.json`

Written by atomic rename once the socket listens. Every manager serves
`webroot/` with root reads, so the page reads it with a plain
`fetch('/.run/session.json?n=<nonce>', {cache: 'no-store'})`, without the bridge.

```json
{
  "protocol": 1,
  "version": "0.1.0",
  "port": 41234,
  "token": "<43 chars, base64url, 256 random bits>",
  "pid": 1234,
  "boot": "<contents of /proc/sys/kernel/random/boot_id>",
  "started": "2026-10-01T05:30:00.000Z"
}
```

Page start (`RootChannel.connect()` in `flutter_webui_client` does this):
1. Fetch `session.json`. If present and `version` matches, connect.
2. If it is missing, refused, rejected, or another `version`: start the channel
   (after `shutdown` to a live channel of another version), then poll
   `session.json` until a file with a new `pid` appears (50 ms steps, 5 s cap).
3. The start command is the only string the page passes to the bridge, each
   part quoted by `flutter_webui_client`:
   `sh '<moddir>/flutter_webui/root' start`
   It returns at once (so the blocking `ksu.exec` on KernelSU-family managers
   costs only the fork). The channel runs in its own session with stdin from
   `/dev/null`, so the manager closing its shell (WebUI X
   `killShellWhenBackground`) does not end it. A second start while one runs
   exits without effect (the `lock` file).

## Connection

`ws://127.0.0.1:<port>/v1?token=<token>`

- Wrong token: HTTP 401 (compared in constant time). `Origin` other than
  `https://mui.kernelsu.org`, or more than one `Origin`: 403. No `Origin` (a
  non-browser client) is accepted with the token.
- At most 16 open connections (`maxConnections`); past it, and while the
  channel shuts down, an upgrade gets HTTP 503.
- No WebSocket extensions: `permessage-deflate` is not negotiated.
- The server pings every 15 s. The WebView's network stack answers pings
  while page timers are paused, so a hidden page stays connected.
- Several connections may be open; each owns the processes it starts.
- With no connection and no attached process for 30 s, the channel removes
  `session.json` and exits.

## Frames

Text frames are JSON. Binary frames carry stream bytes:

```
byte 0      stream: 0 = stdin (page -> process), 1 = stdout, 2 = stderr
bytes 1-4   id of the process (uint32, big endian), as given in `start`
bytes 5..   payload (at least 1 byte)
```

On connect the server sends:

```json
{"op": "hello", "protocol": 1, "version": "0.1.0", "pid": 1234, "boot": "...", "uid": 0, "moduleDir": "/data/adb/modules/<id>"}
```

### Requests (page -> server)

Every request carries an `id` (1 to 2^32-1) chosen by the page; `start` uses it
as the process id on this connection (an id is in use from the `start` until
its `exit`). Failures answer
`{"op":"error","id":n,"code":c,"message":"..."}` with `c` one of:

| Code | Meaning |
|---|---|
| `bad-request` | malformed request or frame |
| `duplicate-id` | `start` with an id in use on this connection |
| `no-such-process` | no running process with that id on this connection |
| `not-found` | `read`: no such regular file inside the module |
| `start-failed` | the process could not be started (or the channel is shutting down) |
| `too-large` | `read`: the file is over 64 KiB |
| `request-too-large` | a text frame over 512 KiB (`maxRequestBytes`; `id` is null), or a `start` whose `argv` and `env` are over 128 KiB (`maxArgvEnvBytes`, every argument and every `KEY=value` as UTF-8 plus a terminator) |
| `too-many-processes` | `start` past 64 running processes on this connection (`maxProcessesPerConnection`) or 256 in the channel (`maxProcesses`); a detached process counts until its `exit` or its owner's disconnect |
| `stdin-overflow` | over 1 MiB (`maxStdinBufferBytes`) of stdin waits for an attached process that does not read it; that frame is dropped and the process's stdin is closed after the bytes already held. A frame that arrives while nothing waits is taken whole. |

The limits are constants in `lib/protocol.dart`. A request answered with an
error has no other effect, and the connection stays open.

| Request | Fields | Answer |
|---|---|---|
| `start` | `argv` (non-empty list of strings without NUL; `argv[0]` a non-empty absolute path or a name on `PATH`); optional `cwd` (absolute path), `env` (string map merged over the channel's root environment; names non-empty without `=` or NUL, values without NUL), `detached` (bool, default false) | `{"op":"started","id":n,"pid":p}`, later `{"op":"exit","id":n,"code":c}` |
| `close-stdin` | `id` | none |
| `signal` | `id`, `signal`: `TERM` `KILL` `INT` `HUP` `USR1` `USR2` `STOP` `CONT` | none |
| `read` | `path`: absolute; must resolve (symlinks too) to a regular file inside the module directory; at most 64 KiB of UTF-8 | `{"op":"read","id":n,"data":"..."}` |
| `shutdown` | | ends attached processes, removes `session.json`, exits |

Stdin bytes go as binary frames with stream 0 and the process id.

## Processes

Processes are executed directly, never through a shell. For a shell, send
`argv: ["/system/bin/sh", "-c", script]`.

**Attached** (default): stdin, stdout and stderr are pipes to the channel.
Output streams to the owner as it is read (no flow control; send bulk data by
path, not through stdout). `exit` follows the last output frame; `code` is the
exit code, or minus the signal number if a signal ended it. When the owner's
connection closes, or the channel exits, the process gets `TERM`, then `KILL`
3 s later.

**Detached** (`"detached": true`), for a process that must outlive the page and
the channel, such as an app's root process:
- It runs in its own session with stdin from `/dev/null`, under a small
  wrapper shell that records its exit code. The channel does not reap it and
  never ends it; the process's own rules do (squadron_process: a grace window
  after its last page link closes).
- stdout and stderr go together to `.run/proc/<stamp>.log`; the channel
  streams that log to the owner as stream 1 while the owner is connected.
- `exit` reports the code the wrapper recorded (`128 + n` for signal `n`).
- `signal` goes to the process group, so it reaches the process; the wrapper
  only records the result. `close-stdin` and stdin frames are ignored.
- When the owner disconnects the channel stops streaming and forgets the
  process. A later page finds it again through the process's own session file
  (read it with `read`), not through the channel.

## Example: starting an app's root process

```
-> {"op":"start","id":1,"detached":true,
    "argv":["/data/adb/modules/demo/flutter_webui/x86_64/dartaotruntime","/data/adb/modules/demo/bin/demo.aot",
            "serve","--session-file","/data/adb/modules/demo/webroot/.run/demo.place.json"],
    "env":{"SQUADRON_PROCESS_TOKEN":"..."}}
<- {"op":"started","id":1,"pid":4242}
<- [1][0 0 0 1] {"squadron_process":1,"port":40111,"token":"...","pid":4243}\n
   ... page reloads, connects again ...
-> {"op":"read","id":1,"path":"/data/adb/modules/demo/webroot/.run/demo.place.json"}
<- {"op":"read","id":1,"data":"{\"squadron_process\":1,\"port\":40111,...}"}
```

## Page client (`package:flutter_webui_client`)

Plain Dart against a stock SDK, so apps and generated code depend on it
directly; the `flutter_webui` web plugin is only for the engine handlers.

```dart
import 'package:flutter_webui_client/flutter_webui_client.dart';

WebUi.host;             // WebUiHost: kind, moduleId, moduleDir, ksuMethods
final channel = await WebUi.connectRootChannel();  // discovery + start as above
final p = await channel.start(['/system/bin/id']); // RootProcess
p.stdout; p.stderr;     // Stream<List<int>>
p.stdin;                // StreamSink<List<int>>; close() sends close-stdin
p.kill(signal);         // signal
await p.exitCode;       // int, as above
await channel.start(argv, detached: true);         // stdout = the log
await channel.read(path);                          // String
channel.moduleDir;      // from hello
```
