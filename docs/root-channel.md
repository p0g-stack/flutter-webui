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

## Files

```
<moddir>/flutter_webui/
  root                       POSIX sh launcher (packages/flutter_webui_root/module/root)
  <abi>/flutter_webui_root.aot   AOT snapshot of bin/flutter_webui_root.dart
  <abi>/dartaotruntime       Dart AOT runtime that runs on Android
  <abi>/ld-linux-*.so.*, lib*.so.*   only for a linux (glibc) runtime: its loader and libc
  run/                       0700, root-only; gone with the module directory
    start.lock               0600, held by one `root start` at a time
    lock                     0600, held while a channel runs; holds its pid
    root.log                 0600, channel stderr, truncated on each start
    proc/                    0700
    proc/<stamp>.log, .exit  0600, output and exit code of detached processes (16 newest kept)
    proc/.boot               boot id the files in proc/ are from
/data/adb/<id>/tmp/          0700, the module's TMPDIR (the channel's and what it
                             starts; the launcher sets it, as root shells may
                             start with an empty environment); emptied on the
                             first start of each boot
```

Nothing of the channel is in `webroot/`, which the manager serves. Modes are
set explicitly (`chmod`), not left to the umask of whatever shell started the
channel; the channel never changes its own umask, so processes it starts keep
the one they inherit.

KernelSU module config (`ksud module config`, KernelSU and KernelSU Next
v3.0.0+, required), in tmp.config, which ksud clears each boot (and on a
late-load):

| Key | Value | Written by |
|---|---|---|
| `webui.session` | the session (below) as one JSON value | the channel once it listens; on exit it removes the key if the key still names its pid |
| `webui.boot` | the boot id (`/proc/sys/kernel/random/boot_id`) whose first start emptied `/data/adb/<id>/tmp` | the launcher |

The install marker `webui.installed` (persist.config) is set by the module's
`customize.sh` (flutter_p0g); the channel does not touch it. Every `ksud`
call runs with `KSU_MODULE=<id>`, which a manager's `exec` does not set.

`<abi>` is `arm64-v8a` or `x86_64`. `flutter_p0g` compiles the snapshot and
ships the runtime: stock `dart compile exe` has no Android target. Either an
Android-built `dartaotruntime`, or the SDK's linux `dartaotruntime` with the
glibc loader and libc/libm/libdl/libpthread next to it. The launcher picks
the loader when one is present.

## Start: `root start` prints the session

The page runs this through the bridge, the only command it passes to it,
each part quoted by `flutter_webui_client`:

```
sh '<moddir>/flutter_webui/root' start
```

It prints one line, the session of a live channel of this version, and exits
0; or it writes a message on stderr and exits non-zero. Nothing else goes to
stdout.

```json
{"protocol": 1, "version": "0.2.1", "port": 41234,
 "token": "<43 chars, base64url, 256 random bits>", "pid": 1234,
 "boot": "<boot_id>", "started": "2026-10-01T05:30:00.000Z"}
```

Under `run/start.lock`, `root start`:
1. **Boot marker.** If `webui.boot` is not this boot, empties
   `/data/adb/<id>/tmp` and sets it.
2. **Live session.** If `webui.session` is from this boot and its pid runs,
   connects with its token and reads the hello. Same version: prints the
   session. Another version: sends `shutdown`.
3. **New channel.** Otherwise ends a channel that holds `run/lock` without a
   usable session (`SIGTERM` to the pid in `lock`, if its command line is the
   channel's), then starts `root serve` detached: its own session, stdin from
   `/dev/null`, stderr to `run/root.log`, so neither the launcher exiting nor
   the manager closing its shell (WebUI X `killShellWhenBackground`) ends it.
   The channel takes `run/lock` (waiting up to 10 s for one that is shutting
   down), listens, writes `webui.session`, and prints the session on stdout;
   the launcher passes it on (15 s cap).

On KernelSU-family managers `exec` blocks the page thread while the command
runs: tens of milliseconds for a live channel, a few hundred for a first
start. Nothing else is needed to find the channel: no file is fetched.

While it runs, the channel holds the module's app plane app
(`com.webui.api.<seg>`, `<seg>` as in `webui_app_plane`) as a foreground
service, so Android does not freeze the app between broadcasts: after
announcing it runs `am start-foreground-service --user 0 -n
com.webui.api.<seg>/com.termux.api.RootHelperService` when `pm path` finds
the app (webui-termux-api webui.7 and later), and at shutdown
(idle exit or a signal) `am stopservice` for the same component. Both are best
effort: a missing app or service is logged in `run/root.log` and changes
nothing else.

Page start (`RootChannel.connect()` in `flutter_webui_client`): run
`root start`, connect to the session it printed, and run it once more if that
channel refused the connection (it was exiting while idle).

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
  its session and exits.

## Frames

Text frames are JSON. Binary frames carry stream bytes:

```
byte 0      stream: 0 = stdin (page -> process), 1 = stdout, 2 = stderr
bytes 1-4   id of the process (uint32, big endian), as given in `start`
bytes 5..   payload (at least 1 byte)
```

On connect the server sends:

```json
{"op": "hello", "protocol": 1, "version": "0.2.1", "pid": 1234, "boot": "...", "uid": 0, "moduleDir": "/data/adb/modules/<id>"}
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
| `shutdown` | | ends attached processes, removes its session, exits |

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
- stdout and stderr go together to `run/proc/<stamp>.log`; the channel
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
            "serve","--session-file","/data/adb/modules/demo/run/demo.place.json"],
    "env":{"SQUADRON_PROCESS_TOKEN":"..."}}
<- {"op":"started","id":1,"pid":4242}
<- [1][0 0 0 1] {"squadron_process":1,"port":40111,"token":"...","pid":4243}\n
   ... page reloads, connects again ...
-> {"op":"read","id":1,"path":"/data/adb/modules/demo/run/demo.place.json"}
<- {"op":"read","id":1,"data":"{\"squadron_process\":1,\"port\":40111,...}"}
```

## Page client (`package:flutter_webui_client`)

Plain Dart against a stock SDK, so apps and generated code depend on it
directly; the `flutter_webui` web plugin is only for the engine handlers.

```dart
import 'package:flutter_webui_client/flutter_webui_client.dart';

WebUi.host;             // WebUiHost: kind, moduleId, moduleDir, ksuMethods
final channel = await WebUi.connectRootChannel();  // root start, as above
final p = await channel.start(['/system/bin/id']); // RootProcess
p.stdout; p.stderr;     // Stream<List<int>>
p.stdin;                // StreamSink<List<int>>; close() sends close-stdin
p.kill(signal);         // signal
await p.exitCode;       // int, as above
await channel.start(argv, detached: true);         // stdout = the log
await channel.read(path);                          // String
channel.moduleDir;      // from hello
```
