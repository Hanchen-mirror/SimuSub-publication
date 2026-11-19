import AppKit
import Foundation

/// Optional adapters share one route. A missing adapter never prevents public access.
struct LiveBrowserConnection: LiveBrowserReading {
    let port: any LiveBrowserReading
    let bridge: any LiveBrowserReading
    init(port: any LiveBrowserReading = LiveBrowserPort(), bridge: any LiveBrowserReading = LiveBrowserBridge()) {
        self.port = port; self.bridge = bridge
    }
    func page(_ url: URL, player: Bool) async -> [String: Any]? {
        if let result = await port.page(url, player: player) { return result }
        return await bridge.page(url, player: player)
    }
}

/// Uses an already-running browser's supported local bridge; never launches a browser.
struct LiveBrowserBridge: LiveBrowserReading {
    func page(_ url: URL, player: Bool) async -> [String: Any]? {
        guard LiveBrowserPort.supports(url) else { return nil }
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.citrolabs.ego.lite" }
        }
        guard running else { return nil }
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ego-browser")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let diagnosticSpace: Int? = {
            let args = CommandLine.arguments
            guard args.contains("--live-monitor-check"), let i = args.firstIndex(of: "--live-browser-space"), i + 1 < args.count else { return nil }
            return Int(args[i + 1])
        }()
        guard let script = Self.script(url: url, player: player, diagnosticSpace: diagnosticSpace) else { return nil }
        let job = BrowserBridgeJob()
        let bytes = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { job.run(executable, script: script) }.value
        } onCancel: { job.cancel() }
        guard !Task.isCancelled, let bytes,
              let line = String(decoding: bytes, as: UTF8.self).components(separatedBy: .newlines).last(where: { $0.hasPrefix("SIMUSUB_BROWSER_RESULT ") }),
              let data = line.dropFirst("SIMUSUB_BROWSER_RESULT ".count).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func script(url: URL, player: Bool, diagnosticSpace: Int?) -> String? {
        guard let bytes = try? JSONSerialization.data(withJSONObject: url.absoluteString, options: .fragmentsAllowed) else { return nil }
        let address = String(decoding: bytes, as: UTF8.self)
        let space = diagnosticSpace.map(String.init) ?? "'SimuSub browser ' + \"\(UUID().uuidString)\""
        if url.path == "/" && !player {
            return """
            const task = await taskSpace(\(space));
            try {
                const cookies = await task.page('p1').cdp('Network.getCookies', {urls:[\(address)]});
                console.log('SIMUSUB_BROWSER_RESULT ' + JSON.stringify({data:{},cookies:cookies.cookies}));
            } finally {
                \(diagnosticSpace == nil ? "await task.finish({keep:[]});" : "")
            }
            """
        }
        return """
        const task = await taskSpace(\(space));
        const page = task.page('p1');
        await page.cdp('Page.addScriptToEvaluateOnNewDocument', {source:'(()=>{const play=HTMLMediaElement.prototype.play;HTMLMediaElement.prototype.play=function(){this.muted=true;return play.call(this)}})()'});
        await page.goto(\(address), {waitUntil:"domcontentloaded",timeout:10000});
        await page.waitForFunction(() => \(player ? "(()=>{const p=document.getElementById('movie_player')?.getPlayerResponse?.() || window.ytInitialPlayerResponse;return !!p?.streamingData || (!!p?.playabilityStatus?.status && p.playabilityStatus.status!=='OK')})()" : "!!window.ytInitialData"), undefined, {timeout:10000});
        const result = await page.evaluate(() => ({capture: typeof document.querySelector('video')?.captureStream === 'function', transport:'bridge', data: \(player ? "document.getElementById('movie_player')?.getPlayerResponse?.() || window.ytInitialPlayerResponse" : "window.ytInitialData"), userAgent:navigator.userAgent}));
        console.log('SIMUSUB_BROWSER_RESULT ' + JSON.stringify(result));
        \(diagnosticSpace == nil ? "await task.finish({keep:[]});" : "")
        """
    }
}

/// Bounded in-memory IPC. This helper only talks to the running browser service.
/// Cancelling it never signals the user's browser or writes session data to disk.
final class BrowserBridgeJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.withLock { cancelled = true; if process?.isRunning == true { process?.terminate() } }
    }
    func run(_ executable: URL, script: String) -> Data? {
        let task = Process(), pipe = Pipe()
        task.executableURL = executable; task.arguments = ["nodejs", "-e", script]
        // The bridge writes script receipts to stderr; capture both channels in memory.
        task.standardOutput = pipe; task.standardError = pipe
        let started = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            process = task
            do { try task.run(); return true } catch { process = nil; return false }
        }
        guard started else { return nil }
        try? pipe.fileHandleForWriting.close()
        let watchdog = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: watchdog)
        var output = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            guard output.count + chunk.count <= 16 * 1024 * 1024 else { cancel(); break }
            output.append(chunk)
        }
        task.waitUntilExit(); watchdog.cancel()
        try? pipe.fileHandleForReading.close()
        return lock.withLock { process = nil; return !cancelled && task.terminationStatus == 0 ? output : nil }
    }
}
