import Darwin
import Foundation

/// Tracks child pids on disk so a crashed app does not leave orphaned ssh processes holding ports.
public struct PIDTracker: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("pids.json")
    }

    public func load() -> [String: Int32] {
        guard let data = SecureFile.read(fileURL),
              let map = try? JSONDecoder().decode([String: Int32].self, from: data) else { return [:] }
        return map
    }

    public func save(_ map: [String: Int32]) {
        if let data = try? JSONEncoder().encode(map) {
            try? SecureFile.write(data, to: fileURL)
        }
    }

    /// SIGTERM every recorded pid that is still an orphaned ssh process.
    public func reapOrphans(isOrphanedSSH: (Int32) -> Bool = PIDTracker.looksLikeOrphanedSSH) {
        for pid in load().values where isOrphanedSSH(pid) { kill(pid, SIGTERM) }
        save([:])
    }

    /// Guards against pid reuse: a pid from a previous run may now belong to an ssh the user
    /// started in a terminal. Ours outlived the app, so launchd (pid 1) has adopted them.
    public static func looksLikeOrphanedSSH(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == "ssh" else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_ppid == 1
    }
}
