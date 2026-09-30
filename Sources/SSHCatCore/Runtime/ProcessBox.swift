import Foundation

// `kill` is ambiguous with Process.terminate's neighborhood; qualify the syscall.

/// Owns a running `Process` so it can be signalled from cancellation handlers and other threads.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    var processIdentifier: Int32 { process.processIdentifier }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process.isRunning
    }

    /// SIGTERM, then SIGKILL after `grace` if it is still alive.
    func terminate(grace: TimeInterval = 3) {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [process] in
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    /// Blocking variant for app shutdown, where no scheduled work will get to run.
    func terminateAndWait(timeout: TimeInterval) {
        lock.lock()
        guard process.isRunning else { lock.unlock(); return }
        process.terminate()
        let pid = process.processIdentifier
        lock.unlock()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning { return }
            usleep(20_000)
        }
        if isRunning { Darwin.kill(pid, SIGKILL) }
    }
}

/// Reads pipes with blocking `read()` on dedicated threads. A tunnel reader stays blocked for as
/// long as ssh runs, which would pin a GCD worker.
enum PipeReader {
    static func lines(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            startThread {
                var pending = Data()
                readLoop(handle) { chunk in
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        continuation.yield(decodeLine(pending[pending.startIndex..<nl]))
                        pending.removeSubrange(pending.startIndex...nl)
                    }
                }
                if !pending.isEmpty { continuation.yield(decodeLine(pending[...])) }
                continuation.finish()
            }
        }
    }

    private static func readLoop(_ handle: FileHandle, _ body: (Data) -> Void) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                body(Data(buffer[0..<n]))
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        withExtendedLifetime(handle) {}
    }

    private static func decodeLine(_ data: Data.SubSequence) -> String {
        var line = String(decoding: data, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }

    private static func startThread(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "sshcat.pipe-reader"
        thread.start()
    }
}
