import Foundation
import Darwin
import SwitcherCore

/// Bounds only this newly spawned helper. Never captures raw output in persistent logs.
enum BoundedCLICommand {
    struct Output: Sendable { let status: Int32; let text: String; let timedOut: Bool }
    static func run(home: URL, executable: URL, arguments: [String], inherited: [String: String],
                                timeoutSeconds: TimeInterval, graceSeconds: TimeInterval, combineStderr: Bool = true,
                                input: Data? = nil) async throws -> Output {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-current-cli-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.environment = inherited
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            if let input {
                let pipe = Pipe()
                let writer = pipe.fileHandleForWriting
                // A bounded, nonblocking write before launch keeps a request
                // header out of the process arguments and off disk.
                guard input.count <= 4096, fcntl(writer.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
                    throw SafetyError("额度请求输入不可用。")
                }
                try writer.write(contentsOf: input)
                try writer.close()
                process.standardInput = pipe
            }
            process.standardOutput = output; process.standardError = combineStderr ? output : FileHandle.nullDevice
            let fd = output.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw SafetyError("官方 CLI 输出通道不可用。") }
            let queue = DispatchQueue(label: "switcher.current-cli-output")
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            // Drain on a single queue. Keep bounded diagnostic text in memory
            // only, and return a classification rather than the raw output.
            let capture = RenewalOutputCapture()
            source.setEventHandler { capture.drain(fd) }
            source.setCancelHandler { try? output.fileHandleForReading.close() }
            source.resume()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
                let terminate = DispatchWorkItem { if process.isRunning { process.terminate() } }
                let forceStop = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                process.terminationHandler = { child in
                    terminate.cancel(); forceStop.cancel(); child.terminationHandler = nil
                    queue.async {
                        capture.drain(fd); source.cancel()
                        let result = Output(status: child.terminationStatus, text: capture.text,
                                            timedOut: ProcessInfo.processInfo.systemUptime >= deadline)
                        continuation.resume(returning: result)
                    }
                }
                do {
                    try process.run()
                    try? output.fileHandleForWriting.close()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: terminate)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds + graceSeconds, execute: forceStop)
                } catch {
                    process.terminationHandler = nil
                    terminate.cancel(); forceStop.cancel()
                    try? output.fileHandleForWriting.close()
                    queue.async { source.cancel(); continuation.resume(throwing: error) }
                }
            }
        }.value
    }
}

private final class RenewalOutputCapture: @unchecked Sendable {
    private var data = Data()
    var text: String { String(decoding: data, as: UTF8.self) }
    func drain(_ fd: Int32) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
                if data.count > 65536 { data.removeFirst(data.count - 65536) }
            } else if count < 0 && errno == EINTR { continue }
            else { return }
        }
    }
}
