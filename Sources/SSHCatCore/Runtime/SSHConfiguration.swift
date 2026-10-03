import Foundation
import Darwin

public struct SSHCapabilities: Sendable {
    private let version: (Int, Int)?

    public init(version: String?) {
        let pattern = try! NSRegularExpression(pattern: #"^OpenSSH_(\d+)\.(\d+)"#)
        let text = (version ?? "") as NSString
        if let match = pattern.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)),
           let major = Int(text.substring(with: match.range(at: 1))),
           let minor = Int(text.substring(with: match.range(at: 2))) {
            self.version = (major, minor)
        } else {
            self.version = nil
        }
    }

    public var supportsReverseSOCKS: Bool { version.map { $0 >= (7, 6) } ?? false }
    public var supportsPermitRemoteOpen: Bool { version.map { $0 >= (8, 5) } ?? false }
}

public enum SSHConfigurationError: Error, Equatable, LocalizedError {
    case timeout, tooLarge, commandFailed(String), invalidOutput

    public var errorDescription: String? {
        switch self {
        case .timeout: return L10n.core("configuration.timeout")
        case .tooLarge: return L10n.core("configuration.too_large")
        case .commandFailed(let output): return L10n.core("configuration.failed", output)
        case .invalidOutput: return L10n.core("configuration.invalid_output")
        }
    }
}

/// The native `ssh -G` key/value protocol, preserving repeated keys and paths containing spaces.
public struct SSHConfiguration: Sendable {
    public let values: [String: [String]]

    public init(output: String) {
        var values: [String: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.count == 2 { values[String(parts[0]).lowercased(), default: []].append(String(parts[1])) }
        }
        self.values = values
    }

    public func value(_ key: String) -> String? { values[key]?.first }

    public func hasAdditionalForwards(comparedTo rule: ForwardRule) -> Bool {
        let counts = ["localforward": rule.forwards.filter { $0.kind == .local }.count,
                      "remoteforward": rule.forwards.filter { $0.kind.isRemote }.count,
                      "dynamicforward": rule.forwards.filter { $0.kind == .dynamic }.count]
        return counts.contains { (values[$0.key]?.count ?? 0) > $0.value }
    }

    /// Only copied for manual use after fingerprint verification. Never executed by the app.
    public func hostKeyRemovalCommand(knownHostsFile: String) -> String? {
        // A jump host may be the one that failed verification; this config only resolves the final host.
        if ["proxyjump", "proxycommand"].contains(where: { value($0).map { $0 != "none" } ?? false }) { return nil }
        guard !SSHToken.containsControl(knownHostsFile), knownHostsFile.hasPrefix("/"),
              let hostname = value("hostname"), SSHToken.isHost(hostname),
              let port = value("port").flatMap(Int.init), SSHToken.isPort(port) else { return nil }
        let alias = value("hostkeyalias").flatMap { $0 == "none" ? nil : $0 }
        if let alias, alias.isEmpty || alias.hasPrefix("-") || SSHToken.containsControl(alias) || alias.contains(where: \.isWhitespace) { return nil }
        let host = SSHToken.sshDestinationHost(hostname)
        let lookup = alias ?? (port == 22 ? host : "[\(host)]:\(port)")
        return ShellQuote.join(["ssh-keygen", "-f", knownHostsFile, "-R", lookup])
    }

    public static func inspect(executable: URL, rule: ForwardRule, identityAgent: String? = nil) async throws -> SSHConfiguration {
        let arguments = ["-G"] + (try rule.arguments(identityAgent: identityAgent))
        let output = try await SSHCommand.output(executable: executable, arguments: arguments)
        let result = SSHConfiguration(output: output)
        guard result.value("hostname") != nil, result.value("port") != nil, result.value("user") != nil else {
            throw SSHConfigurationError.invalidOutput
        }
        return result
    }
}

/// Short-lived local SSH commands only. Read while the child runs to avoid pipe deadlocks.
enum SSHCommand {
    static func output(executable: URL, arguments: [String], timeout: TimeInterval = 5,
                       maximumBytes: Int = 256 * 1024) async throws -> String {
        let job = Task.detached {
            try capture(executable: executable, arguments: arguments, timeout: timeout, maximumBytes: maximumBytes)
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: { job.cancel() }
    }

    private static func capture(executable: URL, arguments: [String], timeout: TimeInterval, maximumBytes: Int) throws -> String {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw CocoaError(.fileReadUnknown) }
        let box = ProcessBox(process)
        defer {
            box.terminateAndWait(timeout: 0.1)
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try process.run()
        try pipe.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var eof = false
        while !eof || process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SSHConfigurationError.timeout }
            if !eof {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard data.count + count <= maximumBytes else { throw SSHConfigurationError.tooLarge }
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                } else if count == 0 {
                    eof = true
                } else if errno != EAGAIN && errno != EINTR {
                    throw CocoaError(.fileReadUnknown)
                }
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw SSHConfigurationError.commandFailed(String(text.suffix(4000))) }
        return text
    }
}
