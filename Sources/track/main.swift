import Foundation
import Darwin
import StatusBarCore

// MARK: - Shell snippets (must be initialized before top-level dispatch runs)

let zshInitSnippet = #"""
# status-bar shell integration (zsh)
status_begin() {
  STATUS_JOB="$(command track begin "$1")"
}
status_end() {
  local _rc=$? _ps=( "${pipestatus[@]}" )
  local c
  for c in "${_ps[@]:-$_rc}"; do
    [[ "$c" != "0" ]] && _rc=$c
  done
  if [[ -n "$STATUS_JOB" ]]; then
    command track end "$STATUS_JOB" "$_rc"
    unset STATUS_JOB
  fi
  return $_rc
}
"""#

let bashInitSnippet = #"""
# status-bar shell integration (bash)
status_begin() {
  STATUS_JOB="$(command track begin "$1")"
}
status_end() {
  local _rc=$? _ps=( "${PIPESTATUS[@]}" )
  local c
  for c in "${_ps[@]:-$_rc}"; do
    [ "$c" != "0" ] && _rc=$c
  done
  if [ -n "$STATUS_JOB" ]; then
    command track end "$STATUS_JOB" "$_rc"
    unset STATUS_JOB
  fi
  return $_rc
}
"""#

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else { printUsage(); exit(2) }

switch sub {
case "list":         runList()
case "clear":        runClear()
case "rm":           runRemove(Array(args.dropFirst()))
case "begin":        runBegin(Array(args.dropFirst()))
case "end":          runEnd(Array(args.dropFirst()))
case "attach":       runAttach(Array(args.dropFirst()))
case "shell-init":   runShellInit(Array(args.dropFirst()))
case "-h", "--help", "help":
    printUsage(); exit(0)
default:
    runWrap(args)
}

// MARK: - Subcommands

func runList() {
    let jobs = ((try? JobStore.loadAll()) ?? []).sorted { $0.startedAt < $1.startedAt }
    for j in jobs {
        let state = j.state.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
        print("\(state) \(j.id)  \(j.name)")
    }
    exit(0)
}

func runClear() {
    for j in ((try? JobStore.loadAll()) ?? []) where j.state != .running {
        JobStore.delete(j.id)
    }
    exit(0)
}

func runRemove(_ args: [String]) {
    guard let id = args.first else { printUsage(); exit(2) }
    JobStore.delete(id)
    exit(0)
}

func runBegin(_ args: [String]) {
    guard let name = args.first, !name.isEmpty else {
        stderr("track begin: missing <name>\n"); exit(2)
    }
    let job = Job(
        id: JobStore.newID(),
        name: name,
        command: args.dropFirst().joined(separator: " "),
        state: .running,
        startedAt: Date(),
        pid: getppid()
    )
    do {
        try JobStore.write(job)
    } catch {
        stderr("track begin: \(error)\n"); exit(1)
    }
    print(job.id)
    exit(0)
}

func runEnd(_ args: [String]) {
    guard let id = args.first else {
        stderr("track end: missing <id>\n"); exit(2)
    }
    let code: Int32 = args.count >= 2 ? (Int32(args[1]) ?? 0) : 0
    let url = JobStore.url(for: id)
    guard var job = try? JobStore.read(url) else {
        stderr("track end: no such job: \(id)\n"); exit(1)
    }
    job.state = code == 0 ? .completed : .failed
    job.endedAt = Date()
    job.exitCode = code
    try? JobStore.write(job)
    exit(0)
}

func runAttach(_ args: [String]) {
    guard let pidStr = args.first, let pid = Int32(pidStr) else {
        stderr("track attach: usage: attach <pid> [name]\n"); exit(2)
    }
    if kill(pid, 0) != 0 {
        let err = errno
        stderr("track attach: pid \(pid) not accessible (errno \(err))\n"); exit(1)
    }
    let name = args.count >= 2
        ? args[1...].joined(separator: " ")
        : "pid \(pid)"

    var job = Job(
        id: JobStore.newID(),
        name: name,
        command: "attached to pid \(pid)",
        state: .running,
        startedAt: Date(),
        // See wrap-mode comment — store track's own PID (the writer), not the
        // target PID. The target dying is exactly what we're observing, so
        // using it for orphan detection would race with the "completed" write.
        pid: getpid()
    )
    try? JobStore.write(job)

    installAttachSignalHandlers(job: job)

    if waitForExit(pid: pid) {
        job.state = .completed
        job.endedAt = Date()
        // No exitCode: NOTE_EXITSTATUS is only delivered to the parent.
        try? JobStore.write(job)
        exit(0)
    } else {
        let err = errno
        job.state = .failed
        job.endedAt = Date()
        job.exitCode = -1
        try? JobStore.write(job)
        stderr("track attach: kqueue wait failed (errno \(err))\n")
        exit(1)
    }
}

func runShellInit(_ args: [String]) {
    let shell = (args.first ?? defaultShell()).lowercased()
    switch shell {
    case "zsh":
        print(zshInitSnippet)
    case "bash", "sh":
        print(bashInitSnippet)
    default:
        stderr("track shell-init: unsupported shell '\(shell)' (try bash or zsh)\n")
        exit(2)
    }
    exit(0)
}

func runWrap(_ args: [String]) {
    guard let dashDash = args.firstIndex(of: "--"), dashDash > 0, dashDash + 1 < args.count else {
        printUsage(); exit(2)
    }

    let name = args[0..<dashDash].joined(separator: " ")
    let cmdParts = Array(args[(dashDash + 1)...])

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = cmdParts
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    var job = Job(
        id: JobStore.newID(),
        name: name,
        command: cmdParts.joined(separator: " "),
        state: .running,
        startedAt: Date(),
        // Store track's own PID — the writer. The orphan reaper checks this
        // to detect a dead writer, NOT the child's PID. Using the child here
        // races with the final "completed" write the instant the child exits.
        pid: getpid()
    )
    try? JobStore.write(job)

    installWrapSignalHandlers(job: job)

    do {
        try process.run()
    } catch {
        job.state = .failed
        job.endedAt = Date()
        job.exitCode = -1
        try? JobStore.write(job)
        stderr("track: failed to launch: \(error)\n")
        exit(1)
    }

    process.waitUntilExit()
    job.state = process.terminationStatus == 0 ? .completed : .failed
    job.endedAt = Date()
    job.exitCode = process.terminationStatus
    try? JobStore.write(job)
    exit(process.terminationStatus)
}

// MARK: - kqueue wait

func waitForExit(pid: Int32) -> Bool {
    let kq = kqueue()
    if kq < 0 { return false }
    defer { close(kq) }

    // NOTE_EXIT = 0x80000000 — imported from C as a negative Int32 in Swift,
    // so UInt32(NOTE_EXIT) traps. Use the bit-pattern literal directly.
    var change = kevent(
        ident: UInt(pid),
        filter: Int16(EVFILT_PROC),
        flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
        fflags: 0x8000_0000 as UInt32,
        data: 0,
        udata: nil
    )
    var out = kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil)
    let n = kevent(kq, &change, 1, &out, 1, nil)
    return n == 1
}

// MARK: - Signal handling

func installWrapSignalHandlers(job: Job) {
    let mutableJob = JobRef(job)
    let handler: @Sendable (Int32) -> Void = { signo in
        var j = mutableJob.value
        j.state = .failed
        j.endedAt = Date()
        j.exitCode = 128 + signo
        try? JobStore.write(j)
        exit(128 + signo)
    }
    installSignal(SIGINT, handler)
    installSignal(SIGTERM, handler)
    installSignal(SIGHUP, handler)
}

func installAttachSignalHandlers(job: Job) {
    let mutableJob = JobRef(job)
    let handler: @Sendable (Int32) -> Void = { signo in
        var j = mutableJob.value
        j.state = .failed
        j.endedAt = Date()
        j.exitCode = 128 + signo
        try? JobStore.write(j)
        exit(128 + signo)
    }
    installSignal(SIGINT, handler)
    installSignal(SIGTERM, handler)
    installSignal(SIGHUP, handler)
}

private final class JobRef: @unchecked Sendable {
    var value: Job
    init(_ value: Job) { self.value = value }
}

// Static-stored property is lazily initialized regardless of source order —
// safe to touch from top-level code that runs before the file's tail.
private enum SignalState {
    static var sources: [DispatchSourceSignal] = []
}

private func installSignal(_ signo: Int32, _ handler: @escaping @Sendable (Int32) -> Void) {
    // .global() queue, not .main — a plain CLI doesn't drive the main queue.
    let src = DispatchSource.makeSignalSource(signal: signo, queue: .global())
    src.setEventHandler { handler(signo) }
    src.resume()
    SignalState.sources.append(src)
    signal(signo, SIG_IGN)
}

// MARK: - Helpers

func stderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

func defaultShell() -> String {
    let s = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    return (s as NSString).lastPathComponent
}

func printUsage() {
    let msg = """
    usage:
      track <name> -- <command> [args...]   run a command and track it
      track begin <name>                    start tracking; prints job id
      track end <id> [exit-code]            finalize a tracked job
      track attach <pid> [name]             wait for an existing pid to exit
      track list                            list tracked jobs
      track clear                           remove completed/failed jobs
      track rm <id>                         remove a specific job
      track shell-init [bash|zsh]           print shell helper functions

    examples:
      track build -- npm run build
      track tests -- pytest -x

      # in a script, after `eval "$(track shell-init zsh)"`:
      status_begin "deploy"
      ./deploy.sh && run-migrations
      status_end

      # for an existing process:
      track attach 12345 "long backup" &

    """
    stderr(msg)
}

