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
<moddir>/webroot/.run/
  session.json               written by the channel (below)
  root.log                   channel stderr, truncated on each start
  lock                       held while a channel runs
  proc/<stamp>.log, .exit    output and exit code of detached processes (16 newest kept)
```

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

- Wrong token: HTTP 401. `Origin` other than `https://mui.kernelsu.org`: 403.
  No `Origin` (a non-browser client) is accepted with the token.
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
as the process id on this connection. Failures answer
`{"op":"error","id":n,"code":c,"message":"..."}` with `c` one of
`bad-request`, `duplicate-id`, `no-such-process`, `not-found`, `start-failed`,
`too-large`.

| Request | Fields | Answer |
|---|---|---|
| `start` | `argv` (non-empty list of strings; `argv[0]` an absolute path or a name on `PATH`); optional `cwd`, `env` (string map merged over the channel's root environment), `detached` (bool, default false) | `{"op":"started","id":n,"pid":p}`, later `{"op":"exit","id":n,"code":c}` |
| `close-stdin` | `id` | none |
| `signal` | `id`, `signal`: `TERM` `KILL` `INT` `HUP` `USR1` `USR2` `STOP` `CONT` | none |
| `read` | `path`: absolute; must resolve (symlinks too) inside the module directory; at most 64 KiB of UTF-8 | `{"op":"read","id":n,"data":"..."}` |
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
