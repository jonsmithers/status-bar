import Foundation
import Darwin
import StatusBarCore

@MainActor
final class JobsObservable: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pollTimer: Timer?

    init() {
        try? JobStore.ensureDirectory()
        reload()
        startWatching()
        startPolling()
    }

    deinit {
        source?.cancel()
        if fd >= 0 { close(fd) }
        pollTimer?.invalidate()
    }

    var runningCount: Int { jobs.filter { $0.state == .running }.count }
    var failedCount: Int { jobs.filter { $0.state == .failed }.count }
    var completedCount: Int { jobs.filter { $0.state == .completed }.count }

    func reload() {
        var loaded = ((try? JobStore.loadAll()) ?? [])
            .sorted { $0.startedAt > $1.startedAt }
        reapOrphans(in: &loaded)
        self.jobs = loaded
    }

    /// If a job is `running` but its stored pid no longer exists, mark it as failed.
    /// Covers the case where the shell died before calling `status_end` or `track end`.
    private func reapOrphans(in jobs: inout [Job]) {
        for i in jobs.indices {
            guard jobs[i].state == .running, let pid = jobs[i].pid else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                jobs[i].state = .failed
                jobs[i].endedAt = Date()
                jobs[i].exitCode = -1
                try? JobStore.write(jobs[i])
            }
        }
    }

    func clearFinished() {
        for j in jobs where j.state != .running {
            JobStore.delete(j.id)
        }
        reload()
    }

    func remove(_ job: Job) {
        JobStore.delete(job.id)
        reload()
    }

    private func startWatching() {
        let path = JobStore.directory.path
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        s.setEventHandler { [weak self] in
            self?.reload()
        }
        s.resume()
        source = s
    }

    private func startPolling() {
        // Backup poll: catches in-place rewrites that the dir watcher can miss,
        // and keeps "running" elapsed times ticking in the menu.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
            }
        }
    }
}
