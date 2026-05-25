# status-bar

Track long-running terminal jobs from your macOS menu bar.

Two pieces, communicating via JSON files in `~/.status-bar/jobs/`:

- **`track`** — a CLI that records job state to disk. Has subcommands for wrapping a command, fencing a shell block, attaching to an existing PID, and shell integration.
- **`StatusBarApp`** — a SwiftUI menu bar app that watches that directory and shows running / completed / failed jobs.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for design notes (data model, on-disk format, kqueue attach, orphan reaping).

## Build

    swift build -c release

Outputs:

    .build/release/track
    .build/release/StatusBarApp

For an iteration loop:

    swift build -c release && .build/release/track list

## Install

Put the CLI somewhere on your `PATH`:

    cp .build/release/track /usr/local/bin/track     # or ~/bin/track

Run the menu bar app (background it; consider adding to Login Items):

    .build/release/StatusBarApp &

## Shell integration

Add this to `~/.zshrc` (or `~/.bashrc`):

    eval "$(track shell-init zsh)"          # or: track shell-init bash

That defines two functions:

    status_begin <name>   # starts a tracked job, stores its id in $STATUS_JOB
    status_end            # finalizes it using $? (and PIPESTATUS / pipestatus)

## Usage

Wrap a single command:

    track build -- npm run build
    track tests -- pytest -x
    track ci    -- sh -c 'lint && test && build'      # use sh -c for shell features

Fence a block of shell:

    status_begin "deploy"
    ./deploy.sh && run-migrations && smoke-test
    status_end

Attach to an already-running process:

    track attach 12345 "backup job"

    # or to attach to a backgrounded job in the same shell:
    long-running-thing &
    track attach $! "long thing" &

Inspect / clean:

    track list             # show all tracked jobs
    track clear            # remove completed and failed jobs
    track rm <id>          # remove one
    track shell-init zsh   # print the shell snippet (used by `eval` above)

## Tests

End-to-end tests live in `tests/integration.sh`. They build the binary, then run each scenario against a temporary `$HOME` so test data doesn't pollute `~/.status-bar/jobs/`.

    tests/integration.sh

Covers: wrap success/failure, begin+end success/failure, zsh and bash pipeline failures, attach completion, attach interrupted by SIGINT.

## Notes

- `track <name> -- <cmd>` streams the command's stdout/stderr through your terminal as normal; the job file is updated atomically on start, when the PID is assigned, and when the command exits.
- Attached jobs always finalize as `completed`. macOS only delivers exit status (via `NOTE_EXITSTATUS`) to the parent of a process; as a non-parent observer we learn *that* it exited but not *how*.
- If a shell using `status_begin` dies before `status_end` runs, the menu bar app reaps the job on its next refresh by checking that the stored PID still exists (`kill(pid, 0)`).
