# Architecture

## What this is

A macOS menu bar app that displays the live state of long-running terminal jobs, paired with a `track` CLI that writes that state from your shell.

The two halves communicate exclusively through JSON files in `~/.status-bar/jobs/`. There is no daemon, no socket, no shared library at runtime — either half works in isolation.

## Components

```
status-bar/
├── Sources/
│   ├── StatusBarCore/       # shared data model + on-disk format
│   │   └── Job.swift
│   ├── track/               # CLI (multi-subcommand)
│   │   └── main.swift
│   └── StatusBarApp/        # SwiftUI MenuBarExtra app
│       ├── StatusBarApp.swift
│       ├── JobsObservable.swift
│       └── JobsMenuView.swift
└── Package.swift
```

## Data model

A `Job` is the unit of work:

```swift
struct Job: Codable {
    var id: String          // "20260525-181821-a8bd76"
    var name: String        // human label
    var command: String     // best-effort string form of what's running
    var state: JobState     // running | completed | failed
    var startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var pid: Int32?         // semantics depend on origin — see below
}
```

### `pid` semantics — the writer, not the subject

`pid` always stores the PID of **the process responsible for finalizing this job's JSON file** — i.e., the writer. The reaper's check "if `state == running` and `kill(pid, 0) == ESRCH`, mark failed" is correct only under this invariant.

| Source             | What `pid` stores            | Why                                                         |
| ------------------ | ---------------------------- | ----------------------------------------------------------- |
| `track <n> -- ...` | track's own PID              | track owns the lifecycle; it writes the final state         |
| `track attach`     | track's own PID              | the kqueue watcher owns the lifecycle; the target's PID is the subject, not the writer |
| `track begin`      | the calling shell's PID (PPID) | `status_end` runs in the shell; if the shell dies, no finalize |

Why this matters — earlier versions stored the *child's* PID in wrap mode and the *target's* PID in attach mode. That created a race: the instant the child exited, its PID became invalid in the kernel; if the menu app's 1s poll happened to fire in the few-ms window before track wrote the final `completed`, the reaper would write `failed -1` over a successful job. Using the writer's PID closes that window entirely: as long as track is alive, the job stays in `running`; once track has exited, the file is already finalized.

The "subject" PID (child / target) isn't stored at all right now. If a future "kill job from menu" feature needs it, add a separate `childPid` field — don't repurpose this one.

## On-disk format

```
~/.status-bar/jobs/<id>.json    one file per job
```

- One job per file. Atomic writes (`Data.write(atomic:)`) — readers never see torn JSON.
- Dates encoded as ISO-8601, keys sorted, pretty-printed (for human grepping).
- The directory is the source of truth. Removing a file removes the job.

## Processes

### `track <name> -- <cmd> [args...]`

The original mode. `track` is the parent of the spawned process.

1. Generate id, write JSON with `state: running`.
2. `exec` the command with inherited stdio (user still sees output in their terminal).
3. Update JSON with the child's PID.
4. `waitUntilExit()`, then write JSON with `completed` / `failed` and the exit code.
5. SIGINT/SIGTERM handlers mark the job failed with code `128 + signal` before exiting.

### `track begin <name>` → prints id, `track end <id> [code]`

For wrapping shell pipelines, scripts, or anything where `track <n> -- <cmd>` is too rigid.

- `begin` writes a `running` job, stores `getppid()` as `pid`, and prints the id to stdout.
- `end` reads the JSON, updates `state`/`exitCode`/`endedAt`, and writes it back.
- Default exit code is `0`. Anything non-zero → `failed`.

### `track attach <pid> [name]`

Wait on a process we did not spawn. Implemented via `kqueue` with `EVFILT_PROC` and `NOTE_EXIT`.

```c
kq = kqueue();
kevent(kq, &{ ident=pid, filter=EVFILT_PROC, flags=EV_ADD, fflags=NOTE_EXIT }, 1, NULL, 0, NULL);
kevent(kq, NULL, 0, &out, 1, NULL);   // blocks until process exits
```

**Exit-code limitation.** macOS only delivers the exit status (via `NOTE_EXITSTATUS`) to the actual parent of the process. As a non-parent observer, we learn *that* the process ended but not *how*. Attached jobs therefore always finalize as `completed`, regardless of the real exit code. This is a kernel constraint, not a design choice.

### `track shell-init [bash|zsh]`

Prints a snippet to `eval` from `~/.bashrc` or `~/.zshrc`. The snippet defines:

```bash
status_begin <name>   # sets $STATUS_JOB to a new id
status_end            # finalizes $STATUS_JOB using $? (and $pipestatus / ${PIPESTATUS[@]})
```

`status_end` is careful to capture both `$?` and the pipeline status array on the **first line** of the function — `local var=$?` on its own would reset `$?` before we could read PIPESTATUS.

## Menu bar app

Single SwiftUI `MenuBarExtra` scene, `.window` style (popover with full SwiftUI freedom, not the limited `.menu` style).

### Update cycle

`JobsObservable` runs two parallel mechanisms:

1. **`DispatchSource` directory watcher** on `~/.status-bar/jobs/` — fires on file create/delete/rename and dir mtime updates. Catches new jobs and state transitions immediately.
2. **1-second poll** — keeps elapsed-time labels ticking for running jobs and serves as a backstop for in-place rewrites that might not bump the dir mtime.

Both call `reload()`, which re-reads the directory, sorts by `startedAt`, and triggers SwiftUI updates via `@Published`.

### Orphan reaping

After each `reload()`, any job with `state == .running` and a non-nil `pid` is checked with `kill(pid, 0)`:

- success → process alive, leave it
- `ESRCH` → process gone, mark `failed` with exit code `-1`, write JSON back

This protects against shells that die mid-job (closed terminal, crashed script before `status_end`).

`kill(pid, 0)` is a permission check that doesn't actually signal — safe to call on every poll.

### Status bar icon

The label changes based on aggregate state, in priority order:

1. running > 0 → `circle.dotted` + count
2. failed > 0 → `exclamationmark.circle.fill`
3. completed > 0 → `checkmark.circle`
4. otherwise → `circle.dashed`

The dropdown header shows per-state counts; the body lists each job with its own colored icon, name, command, runtime, and exit code.

## Design decisions worth remembering

- **No daemon.** Two file-based processes that don't need each other to be running. Simplifies install, debugging, and recovery.
- **No auto-tracking via `preexec`.** The user wants signal, not a firehose of every shell command. Explicit `status_begin` / `status_end` keeps the menu meaningful.
- **`.window` style over `.menu` style.** Lets us draw rich rows (icon + name + command + runtime + remove button) instead of being limited to flat menu items.
- **No exit code for attached jobs.** Documented limitation. The alternative (`ptrace`/lldb) requires entitlements and is wildly disproportionate.
- **PID-based orphan reaping.** Cheap, correct, doesn't require process accounting or any privilege.
