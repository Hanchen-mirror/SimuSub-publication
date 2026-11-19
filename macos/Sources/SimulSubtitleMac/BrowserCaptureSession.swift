import Foundation

struct BrowserCaptureRequest: Sendable {
    let address: URL
    let transport: String
}

protocol BrowserCaptureSession: Sendable {
    func evaluate(_ expression: String) async throws -> [String: Any]
    func close() async
}

func browserJSON(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
}

actor BridgeCaptureSession: BrowserCaptureSession {
    private var space: Int?
    private var ownsSpace = true
    private let name = "SimuSub recording " + UUID().uuidString
    private let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ego-browser")
    private func execute(_ script: String) async throws -> [String: Any] {
        let job = BrowserBridgeJob()
        let data = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { job.run(self.executable, script: script) }.value
        } onCancel: { job.cancel() }
        guard let data else { throw LiveMonitorError.unavailable("浏览器连接已中断，已收到的录像保留。") }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        if let marker = lines.last(where: { $0.hasPrefix("SIMUSUB_BROWSER_SPACE ") }), let id = Int(marker.dropFirst("SIMUSUB_BROWSER_SPACE ".count)) { space = id }
        guard let line = lines.last(where: { $0.hasPrefix("SIMUSUB_BROWSER_RESULT ") }),
              let bytes = line.dropFirst("SIMUSUB_BROWSER_RESULT ".count).data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LiveMonitorError.invalidResponse }
        return result
    }
    func open(_ address: URL) async throws {
        let args = CommandLine.arguments
        if args.contains("--live-monitor-check"), let i = args.firstIndex(of: "--live-browser-space"), i + 1 < args.count, let id = Int(args[i+1]) { space = id; ownsSpace = false }
        let selector = try space.map { String($0) } ?? browserJSON(name)
        _ = try await execute("""
        const task=await taskSpace(\(selector)); console.log('SIMUSUB_BROWSER_SPACE '+task.spaceId);
        const page=task.page('p1');
        await page.cdp('Page.addScriptToEvaluateOnNewDocument',{source:'(()=>{const p=HTMLMediaElement.prototype.play;HTMLMediaElement.prototype.play=function(){this.muted=true;return p.call(this)}})()'});
        await page.goto(\(try browserJSON(address.absoluteString)), {waitUntil:"domcontentloaded",timeout:10000});
        await page.waitForFunction(()=>document.querySelector('video')?.readyState>=2,undefined,{timeout:12000});
        console.log('SIMUSUB_BROWSER_RESULT {}');
        """)
    }
    func evaluate(_ expression: String) async throws -> [String: Any] {
        guard let space else { throw LiveMonitorError.invalidResponse }
        return try await execute("""
        const task=await taskSpace(\(space));const page=task.page('p1');
        const result=await page.evaluate(\(try browserJSON(expression)));
        console.log('SIMUSUB_BROWSER_RESULT '+JSON.stringify(result));
        """)
    }
    func close() async {
        guard ownsSpace, let space else { return }
        _ = try? await execute("const task=await taskSpace(\(space));await task.finish({keep:[]});console.log('SIMUSUB_BROWSER_RESULT {}');")
        self.space = nil
    }
}

actor PortCaptureSession: BrowserCaptureSession {
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private var sequence = 0
    private var target: String?
    private var pageSession: String?
    init(socketURL: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 13 * 3600
        session = URLSession(configuration: config)
        socket = session.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 16 * 1024 * 1024; socket.resume()
    }
    private func command(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        sequence += 1; let id = sequence
        var payload: [String: Any] = ["id": id, "method": method, "params": params]
        if let pageSession, !method.hasPrefix("Target.") { payload["sessionId"] = pageSession }
        let watchdog = Task { try? await Task.sleep(nanoseconds: 20_000_000_000); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        defer { watchdog.cancel() }
        try await socket.send(.string(try browserJSON(payload)))
        while true {
            let message = try await socket.receive()
            let data: Data
            switch message { case .string(let value): data = Data(value.utf8); case .data(let value): data = value; @unknown default: continue }
            guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], reply["id"] as? Int == id else { continue }
            guard reply["error"] == nil else { throw LiveMonitorError.unavailable("浏览器未能完成录制请求。") }
            return reply["result"] as? [String: Any] ?? [:]
        }
    }
    func open(_ address: URL) async throws {
        target = try await command("Target.createTarget", ["url": "about:blank", "background": true])["targetId"] as? String
        guard let target else { throw LiveMonitorError.invalidResponse }
        pageSession = try await command("Target.attachToTarget", ["targetId": target, "flatten": true])["sessionId"] as? String
        guard pageSession != nil else { throw LiveMonitorError.invalidResponse }
        _ = try await command("Page.addScriptToEvaluateOnNewDocument", ["source": "(()=>{const p=HTMLMediaElement.prototype.play;HTMLMediaElement.prototype.play=function(){this.muted=true;return p.call(this)}})()"])
        _ = try await command("Page.navigate", ["url": address.absoluteString])
        for _ in 0..<60 {
            if try await evaluate("({ready:document.querySelector('video')?.readyState>=2})")["ready"] as? Bool == true { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw LiveMonitorError.unavailable("浏览器还未播放出画面，请确认网页能播放后重试。")
    }
    func evaluate(_ expression: String) async throws -> [String: Any] {
        let result = try await command("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": true])
        guard result["exceptionDetails"] == nil,
              let value = (result["result"] as? [String: Any])?["value"] as? [String: Any] else { throw LiveMonitorError.unavailable("浏览器暂不支持录制当前画面。") }
        return value
    }
    func close() async {
        if let target { _ = try? await command("Target.closeTarget", ["targetId": target]) }
        socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel()
    }
}
