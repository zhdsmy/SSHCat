import Foundation
import Darwin
import Testing
@testable import SSHCatCore

@Suite struct SSHConfigHostsTests {
    @Test func parsesQuotedEqualsAndMultipleHostPatterns() {
        let text = """
        # Host commented
        Host devbox other # trailing comment
        hOsT=third
        Host =devbox
        Include =one.conf
        Host "odd alias"
        Host 'single quoted'
        Host *.internal ?dynamic !skip
        Include ignored.conf
        Host DEVBOX
        """
        #expect(SSHConfigHosts.parse(text) == ["devbox", "other", "third", "odd alias", "single quoted"])
        #expect(SSHConfigHosts.parse("Host =devbox") == ["devbox"])
    }

    @Test func loadsNestedIncludesGlobAndQuotedPathsInOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("""
        Host before
        Include conf.d/*.conf
        Include =extra.conf
        Include = "extra configs/common.conf"
        Host after
        """, to: root.appendingPathComponent("config"))
        try write("""
        Host alpha duplicate
        Include nested.conf
        Host inline
        """, to: root.appendingPathComponent("conf.d/10-first.conf"))
        try write("Host nested", to: root.appendingPathComponent("nested.conf"))
        try write("Host ALPHA beta", to: root.appendingPathComponent("conf.d/20-second.conf"))
        try write("Host equals_include", to: root.appendingPathComponent("extra.conf"))
        try write("Host \"space alias\"", to: root.appendingPathComponent("extra configs/common.conf"))

        #expect(SSHConfigHosts.load(from: root.appendingPathComponent("config"), includeRoot: root) ==
                ["before", "alpha", "duplicate", "nested", "inline", "beta", "equals_include", "space alias", "after"])
    }

    @Test func cyclesAreSkippedAndMatchExecIsNeverRun() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("should-not-exist")

        try write("""
        Host root
        Include loop.conf
        Match exec "touch \(sentinel.path)"
        Host after
        """, to: root.appendingPathComponent("config"))
        try write("Host nested\nInclude config", to: root.appendingPathComponent("loop.conf"))

        #expect(SSHConfigHosts.load(from: root.appendingPathComponent("config"), includeRoot: root) ==
                ["root", "nested", "after"])
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func ignoresNonRegularIncludeTargets() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe.conf")
        let created = fifo.path.withCString { mkfifo($0, mode_t(S_IRUSR | S_IWUSR)) }
        #expect(created == 0)

        try write("Host regular\nInclude pipe.conf\nHost after", to: root.appendingPathComponent("config"))
        #expect(SSHConfigHosts.load(from: root.appendingPathComponent("config"), includeRoot: root) ==
                ["regular", "after"])
    }

    @Test func capsIncludeDepth() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("Host root\nInclude 1.conf", to: root.appendingPathComponent("config"))
        for index in 1...20 {
            let next = index < 20 ? "\nInclude \(index + 1).conf" : ""
            try write("Host depth\(index)\(next)", to: root.appendingPathComponent("\(index).conf"))
        }

        let hosts = SSHConfigHosts.load(from: root.appendingPathComponent("config"), includeRoot: root)
        #expect(hosts.first == "root")
        #expect(hosts.contains("depth16"))
        #expect(!hosts.contains("depth17"))
    }

    @Test func capsTotalFileCountAndBytes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<270).map { "parts/\(String(format: "%03d", $0)).conf" }
        try write("Include " + paths.joined(separator: " "), to: root.appendingPathComponent("config"))
        for index in 0..<270 {
            try write("Host file\(String(format: "%03d", index))",
                      to: root.appendingPathComponent("parts/\(String(format: "%03d", index)).conf"))
        }
        let fileHosts = SSHConfigHosts.load(from: root.appendingPathComponent("config"), includeRoot: root)
        #expect(fileHosts.count <= 255)
        #expect(fileHosts.first == "file000")
        #expect(!fileHosts.contains("file269"))
        try write("Include parts/*.conf", to: root.appendingPathComponent("config"))
        let globHosts = SSHConfigHosts.load(from: root.appendingPathComponent("config"), includeRoot: root)
        #expect(!globHosts.isEmpty && globHosts.count <= 255)

        let byteRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: byteRoot) }
        try write("Include large/*.conf", to: byteRoot.appendingPathComponent("config"))
        for index in 0..<4 {
            let filler = String(repeating: "x", count: 300_000)
            try write("Host large\(index)\n#\(filler)",
                      to: byteRoot.appendingPathComponent("large/\(index).conf"))
        }
        let byteHosts = SSHConfigHosts.load(from: byteRoot.appendingPathComponent("config"), includeRoot: byteRoot)
        #expect(byteHosts.first == "large0")
        #expect(!byteHosts.contains("large3"))
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SSHCatConfig-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
