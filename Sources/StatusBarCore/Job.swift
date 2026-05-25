import Foundation

public enum JobState: String, Codable, Sendable {
    case running
    case completed
    case failed
}

public struct Job: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var command: String
    public var state: JobState
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var pid: Int32?

    public init(
        id: String,
        name: String,
        command: String,
        state: JobState,
        startedAt: Date,
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        pid: Int32? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.pid = pid
    }
}

public enum JobStore {
    public static var directory: URL {
        // Honor $HOME first so integration tests can isolate via a temp dir.
        // FileManager.default.homeDirectoryForCurrentUser uses the passwd
        // database on macOS and ignores $HOME.
        let home: URL
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty {
            home = URL(fileURLWithPath: h, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(".status-bar/jobs", isDirectory: true)
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    public static func write(_ job: Job) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(job)
        try data.write(to: url(for: job.id), options: .atomic)
    }

    public static func read(_ url: URL) throws -> Job {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Job.self, from: data)
    }

    public static func loadAll() throws -> [Job] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return urls.filter { $0.pathExtension == "json" }.compactMap { try? read($0) }
    }

    public static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    public static func newID() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UInt32.random(in: 0...UInt32.max), radix: 16).prefix(6)
        return "\(fmt.string(from: Date()))-\(suffix)"
    }
}
