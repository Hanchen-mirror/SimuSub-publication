import Foundation
import Darwin

enum LiveTools {
    static var root: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LiveTools") }
    static var launcher: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SimuSubLiveTool") }
    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: launcher.path)
            && ["yt-dlp", "ffmpeg", "ffprobe", "deno"].allSatisfy { FileManager.default.isExecutableFile(atPath: root.appendingPathComponent($0).path) }
    }
    static func executable(_ name: String) throws -> URL {
        guard ["yt-dlp", "ffmpeg", "ffprobe", "deno"].contains(name),
              FileManager.default.isExecutableFile(atPath: launcher.path),
              FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(name).path) else {
            throw LiveMonitorError.unavailable("直播处理组件缺失，请完整解压最新版 SimuSub。")
        }
        return root.appendingPathComponent(name)
    }
    static func run(_ name: String, arguments: [String], timeout: Double = 50) async throws -> LiveToolOutput {
        let job = LiveToolProcess()
        return try await withTaskCancellationHandler {
            try await job.run(name, arguments: arguments, timeout: timeout)
        } onCancel: { job.cancel() }
    }
}

struct LiveToolOutput: Sendable {
    let status: Int32
    let data: Data
    let error: String
}

private final class ToolOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    private(set) var overflow = false
    func consume(_ handle: FileHandle, limit: Int) {
        while let data = try? handle.read(upToCount: 65_536), !data.isEmpty {
            lock.withLock {
                let remaining = max(0, limit - stored.count)
                stored.append(data.prefix(remaining))
                if data.count > remaining { overflow = true }
            }
        }
    }
    var data: Data { lock.withLock { stored } }
}

/// Owns exactly one isolated subprocess. Pipes are drained concurrently; timeout,
/// cancellation, and completion each leave one continuation completion path.
final class LiveToolProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var groupID: Int32?
    private var input: Pipe?
    private var cancelled = false
    private var timedOut = false
    private var stopRequested = false

    func run(_ name: String, arguments: [String], timeout: Double = 50,
             launched: (@Sendable (Int32) -> Void)? = nil) async throws -> LiveToolOutput {
        let executable = try LiveTools.executable(name)
        let process = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = LiveTools.launcher
        process.arguments = [executable.path] + arguments
        // Tools only see explicitly supplied arguments, not a user's yt-dlp
        // config or unrelated browser/session environment.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LiveTools.root.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
        let output = ToolOutputBuffer(), errors = ToolOutputBuffer(), readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async { output.consume(stdout.fileHandleForReading, limit: 8 * 1_024 * 1_024); readers.leave() }
        readers.enter()
        DispatchQueue.global(qos: .utility).async { errors.consume(stderr.fileHandleForReading, limit: 32_768); readers.leave() }
        return try await withCheckedThrowingContinuation { continuation in
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning else { return }
                self.lock.withLock { self.timedOut = true }
                self.signal(SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in self?.signal(SIGKILL) }
            }
            process.terminationHandler = { [self] process in
                readers.notify(queue: .global(qos: .utility)) {
                    watchdog.cancel()
                    // PyInstaller / JS helpers may outlive their immediate
                    // parent briefly. Reap only this launcher's private group.
                    if let pid = self.lock.withLock({ self.groupID }), kill(-pid, 0) == 0 {
                        _ = kill(-pid, SIGTERM)
                        for _ in 0..<20 {
                            if kill(-pid, 0) != 0 { break }
                            usleep(50_000)
                        }
                        if kill(-pid, 0) == 0 { _ = kill(-pid, SIGKILL) }
                    }
                    process.terminationHandler = nil
                    let state = self.lock.withLock {
                        self.process = nil; self.input = nil; self.groupID = nil
                        return (self.cancelled, self.timedOut)
                    }
                    if state.0 { continuation.resume(throwing: CancellationError()) }
                    else if state.1 { continuation.resume(throwing: LiveMonitorError.timeout) }
                    else if output.overflow { continuation.resume(throwing: LiveMonitorError.invalidResponse) }
                    else { continuation.resume(returning: LiveToolOutput(status: process.terminationStatus,
                        data: output.data, error: String(decoding: errors.data, as: UTF8.self))) }
                }
            }
            do {
                lock.withLock { self.process = process; input = stdin }
                try process.run()
                lock.withLock { groupID = process.processIdentifier }
                try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                if lock.withLock({ cancelled }) { signal(SIGTERM) }
                else if lock.withLock({ stopRequested }) { requestStop() }
                launched?(process.processIdentifier)
                DispatchQueue.global().asyncAfter(deadline: .now() + max(1, timeout), execute: watchdog)
            } catch {
                process.terminationHandler = nil
                lock.withLock { self.process = nil; input = nil; groupID = nil }
                try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }

    var isRunning: Bool {
        let state = lock.withLock { (process?.isRunning ?? false, groupID) }
        return state.0 || state.1.map { kill(-$0, 0) == 0 } == true
    }
    var processID: Int32? { lock.withLock { process?.processIdentifier } }

    func requestStop() {
        let writer = lock.withLock { stopRequested = true; return input?.fileHandleForWriting }
        if isRunning { try? writer?.write(contentsOf: Data("q\n".utf8)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.isRunning else { return }
            self.signal(SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.isRunning else { return }; self.signal(SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.signal(SIGKILL) }
            }
        }
    }
    func cancel() {
        lock.withLock { cancelled = true }
        signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.signal(SIGKILL) }
    }
    private func signal(_ value: Int32) {
        let state = lock.withLock { (process, groupID) }
        if let pid = state.1, kill(-pid, 0) == 0 { _ = kill(-pid, value) }
        else if let process = state.0, process.isRunning { _ = kill(process.processIdentifier, value) }
    }
}
