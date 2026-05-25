import SwiftUI
import StatusBarCore

struct JobsMenuView: View {
    @ObservedObject var store: JobsObservable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.jobs.isEmpty {
                Text("No tracked jobs yet.\nRun `track <name> -- <command>` in your terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.jobs) { job in
                            JobRow(job: job) { store.remove(job) }
                            Divider().opacity(0.5)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Status Bar")
                .font(.headline)
            Spacer()
            if store.runningCount > 0 {
                Label("\(store.runningCount) running", systemImage: "circle.dotted")
                    .foregroundStyle(.blue)
            }
            if store.failedCount > 0 {
                Label("\(store.failedCount)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if store.completedCount > 0 {
                Label("\(store.completedCount)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button("Clear finished") { store.clearFinished() }
                .disabled(store.completedCount + store.failedCount == 0)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct JobRow: View {
    let job: Job
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .imageScale(.large)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.body)
                    .lineLimit(1)
                Text(job.command)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(runtime)
                    if let code = job.exitCode, job.state != .running {
                        Text("· exit \(code)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if job.state != .running {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Remove from list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var iconName: String {
        switch job.state {
        case .running: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var runtime: String {
        let end = job.endedAt ?? Date()
        let s = Int(end.timeIntervalSince(job.startedAt))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
