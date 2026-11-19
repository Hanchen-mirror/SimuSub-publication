import Foundation

protocol LiveRecordingControl: AnyObject, Sendable {
    func requestStop()
    func cancel()
}
extension LiveToolProcess: LiveRecordingControl {}

final class BrowserCaptureJob: LiveRecordingControl, @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    func requestStop() { lock.withLock { stopping = true } }
    func cancel() { requestStop() }
    private var shouldStop: Bool { lock.withLock { stopping } }

    func run(_ request: BrowserCaptureRequest, folder: URL, prefix: String, container: String,
             maximumSeconds: Double, segmentSeconds: Double = 300,
             onFrame: @escaping @MainActor @Sendable (URL) -> Void) async throws -> LiveToolOutput {
        let session: any BrowserCaptureSession
        if request.transport == "bridge" {
            let bridge = BridgeCaptureSession(); session = bridge
            do { try await bridge.open(request.address) } catch { await bridge.close(); throw error }
        } else {
            guard let socket = await LiveBrowserPort().captureSocket() else { throw LiveMonitorError.unavailable("浏览器连接已断开。") }
            let port = PortCaptureSession(socketURL: socket); session = port
            do { try await port.open(request.address) } catch { await port.close(); throw error }
        }
        let key = "__simusubCapture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let property = "window['\(key)']"
        var handle: FileHandle?
        var file: URL?
        var written: Int64 = 0
        var marked = false
        var count = 0
        var elapsed: Double = 0
        var segmentStart = Date()
        var lastMediaTime: Double?
        var lastFrameAt = Date()
        let deadline = Date().addingTimeInterval(maximumSeconds)
        let csv = folder.appendingPathComponent(prefix + "browser.csv")
        func finishFile() throws {
            try handle?.synchronize(); try handle?.close(); handle = nil
            guard let file, written > 1024, marked else { if let file { try? FileManager.default.removeItem(at: file) }; return }
            let duration = Date().timeIntervalSince(segmentStart)
            let line = "\(file.lastPathComponent),\(elapsed),\(elapsed + duration)\n"
            if !FileManager.default.fileExists(atPath: csv.path) { _ = FileManager.default.createFile(atPath: csv.path, contents: nil) }
            let index = try FileHandle(forWritingTo: csv); defer { try? index.close() }
            try index.seekToEnd(); try index.write(contentsOf: Data(line.utf8)); elapsed += duration
        }
        func drain(_ batch: [String: Any]) async throws {
            if let message = batch["error"] as? String, !message.isEmpty { throw LiveMonitorError.unavailable("浏览器画面录制中断；已收到的录像保留。") }
            if let time = batch["mediaTime"] as? Double {
                if lastMediaTime == nil || time > (lastMediaTime ?? 0) + 0.05 { lastFrameAt = Date(); lastMediaTime = time }
                else if !shouldStop && Date().timeIntervalSince(lastFrameAt) > 20 {
                    throw LiveMonitorError.unavailable("浏览器画面已停滞 20 秒，正在重新连接；已收到的录像保留。")
                }
            }
            for value in batch["chunks"] as? [String] ?? [] {
                guard let bytes = Data(base64Encoded: value), bytes.count <= 16 * 1024 * 1024 else { throw LiveMonitorError.invalidResponse }
                try handle?.write(contentsOf: bytes); written += Int64(bytes.count)
            }
            if !marked, written > 1024, batch["frame"] as? Bool == true, let file {
                marked = true; await onFrame(file)
            }
        }
        func stopExpression() -> String {
            "(async()=>{const s=\(property);if(!s)return {};if(s.recorder.state!=='inactive'){const done=new Promise(r=>s.recorder.addEventListener('stop',r,{once:true}));s.recorder.stop();await done;}return await s.drain();})()"
        }
        do {
            while !shouldStop && Date() < deadline {
                let info = try await session.evaluate("""
                (async()=>{
                  const v=document.querySelector('video');if(!v?.captureStream)throw Error('capture unavailable');
                  v.muted=true;await v.play();
                  const stream=v.captureStream();if(!stream.getVideoTracks().length||!stream.getAudioTracks().length)throw Error('missing media tracks');
                  const preferred=\(try browserJSON(container == "mp4" ? ["video/mp4;codecs=avc1.42E01E,mp4a.40.2", "video/webm;codecs=vp8,opus"] : ["video/webm;codecs=vp8,opus"]));
                  const mime=preferred.find(t=>MediaRecorder.isTypeSupported(t));if(!mime)throw Error('unsupported codec');
                  const recorder=new MediaRecorder(stream,{mimeType:mime,videoBitsPerSecond:6000000});
                  const s={recorder,stream,chunks:[],bytes:0,error:'',initial:v.currentTime};\(property)=s;
                  s.drain=async()=>{if(v.paused&&!v.ended&&s.recorder.state==='recording'){try{await Promise.race([v.play(),new Promise((_,reject)=>setTimeout(()=>reject(Error('play timeout')),2000))])}catch{s.error='playback paused';}}const parts=s.chunks.splice(0);s.bytes=0;const chunks=[];for(const blob of parts){const a=new Uint8Array(await blob.arrayBuffer());let text='';for(let i=0;i<a.length;i+=8192)text+=String.fromCharCode(...a.subarray(i,i+8192));chunks.push(btoa(text));}return {chunks,error:s.error,frame:v.currentTime>s.initial+0.1,mediaTime:v.currentTime,ended:v.ended};};
                  recorder.ondataavailable=e=>{if(e.data.size){s.chunks.push(e.data);s.bytes+=e.data.size;if(s.bytes>16*1024*1024){s.error='consumer stalled';if(recorder.state!=='inactive')recorder.stop();}}};
                  recorder.onerror=()=>{s.error='media recorder failed';};recorder.start(1000);
                  return {extension:mime.startsWith('video/mp4')?'mp4':\(try browserJSON(container == "mkv" ? "mkv" : "webm"))};
                })()
                """)
                let ext = info["extension"] as? String ?? "webm"
                guard ["mp4", "mkv", "webm"].contains(ext) else { throw LiveMonitorError.invalidResponse }
                file = folder.appendingPathComponent(prefix + String(format: "%06d", count) + "." + ext)
                guard let file, !FileManager.default.fileExists(atPath: file.path), FileManager.default.createFile(atPath: file.path, contents: nil) else { throw LiveMonitorError.unavailable("无法创建浏览器录制文件。") }
                handle = try FileHandle(forWritingTo: file); written = 0; marked = false; segmentStart = Date(); lastMediaTime = nil; lastFrameAt = Date()
                var ended = false
                while !shouldStop && Date() < deadline && Date().timeIntervalSince(segmentStart) < segmentSeconds {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let batch = try await session.evaluate("(async()=>{const s=\(property);if(!s)throw Error('page changed');return await s.drain()})()")
                    try await drain(batch)
                    if batch["ended"] as? Bool == true { ended = true; break }
                }
                try await drain(try await session.evaluate(stopExpression()))
                _ = try? await session.evaluate("(()=>{\(property)?.stream.getTracks().forEach(t=>t.stop());delete \(property);return {}})()")
                try finishFile(); count += 1
                if ended { break }
            }
            await session.close()
            return .init(status: 0, data: Data(), error: "")
        } catch {
            if let batch = try? await session.evaluate(stopExpression()) { try? await drain(batch) }
            _ = try? await session.evaluate("(()=>{\(property)?.stream.getTracks().forEach(t=>t.stop());delete \(property);return {}})()")
            try? finishFile(); await session.close(); throw error
        }
    }
}
