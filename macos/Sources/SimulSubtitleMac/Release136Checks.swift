import Foundation
import AppKit
import AVFoundation
import SwiftUI

private actor Revision136Recognizer: SpeechRecognizing {
    var values: [String]
    init(_ values: [String]) { self.values = values }
    func recognize(samples: [Float]) async throws -> String { values.removeFirst() }
}
private actor Revision136Translator: TextTranslating {
    private(set) var sources: [String] = []
    func translate(_ text: String, from: String, to: String) async throws -> String {
        sources.append(text); return "完整译文：" + text
    }
}
private actor Offline136Service: LivePlatformServing {
    private(set) var attempts = 0
    func search(_ query: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> [CreatorCandidate] { [] }
    func resolve(_ input: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> CreatorCandidate { .init(platform: platform, address: input, name: "离线主播") }
    func status(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> LiveSnapshot { .init(state: .offline) }
    func recordingInput(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> ResolvedLiveInput { attempts += 1; throw LiveExtractionError.offline }
}
@MainActor
enum Release136Checks {
    static func translation() async throws {
        let suite = "SimuSub.v136.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "speech.stablePrefixes.v123")
        let latest = "だからさ高校の受験勉強はほとんどしてなくて"
        let engine = Revision136Translator()
        let model = AppModel(defaults: defaults,
            recognizer: Revision136Recognizer(["高校入っちゃったからさ", latest, "べんきょうしたといったら", "勉強したといったら面接と", "長い日語の草稿を最後まで保存します", "", "以前の長い識別結果をそのままにしない", "短い訂正"]), translator: engine)
        for (index, expected) in [latest, "勉強したといったら面接と", "長い日語の草稿を最後まで保存します", "短い訂正"].enumerated() {
            let id = UUID(), start = Double(index * 10)
            await model.process([0.1, 0.2], start: start, id: id, revision: 1, isFinal: false)
            await model.process([0.1, 0.2, 0.3], start: start, id: id, revision: 2, isFinal: true)
            guard let cue = model.captions.last, cue.original == expected, !cue.isDraft,
                  cue.pendingOriginal == nil, !cue.recognitionNeedsReview,
                  SubtitleDocument.completedTranslation(cue) == "完整译文：" + expected else {
                throw ServiceError.invalidResponse
            }
        }
        let sent = await engine.sources
        guard sent == [latest, "勉強したといったら面接と", "長い日語の草稿を最後まで保存します", "短い訂正"] else { throw ServiceError.invalidResponse }
        try streamCache()
        try layoutAndFolders()
        try await offlineRecording()
        print("v1.36: revised Japanese, empty final fallback and complete-source translation passed")
    }
    static func streamCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simusub-cache-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var creator = WatchedCreator(.init(platform: .bilibili, address: "https://live.bilibili.com/6", name: "测试"))
        creator.snapshot = .init(state: .live, sessionID: "session1")
        let input = ResolvedLiveInput(tracks: [.init(url: URL(string: "https://example.invalid/stream.flv")!, headers: ["Cookie": "secret", "Authorization": "secret", "Referer": creator.address], hasVideo: true, hasAudio: true)], title: "直播")
        BiliStreamCache(root: root).save(input, for: creator, cookies: "secret")
        let reopened = BiliStreamCache(root: root)
        guard reopened.input(for: creator, cookies: "secret")?.title == "直播" else { throw ServiceError.invalidResponse }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard files.count == 1, !(try String(contentsOf: files[0])).contains("secret"),
              reopened.input(for: creator, cookies: "changed") == nil else { throw ServiceError.invalidResponse }
        reopened.save(input, for: creator, cookies: nil, now: Date().addingTimeInterval(-700))
        guard reopened.input(for: creator, cookies: nil) == nil else { throw ServiceError.invalidResponse }
        reopened.save(input, for: creator, cookies: nil)
        creator.snapshot.sessionID = "session2"
        guard reopened.input(for: creator, cookies: nil) == nil else { throw ServiceError.invalidResponse }
        print("v1.36: private stream cache persistence, account/session invalidation and expiry passed")
    }

    static func layoutAndFolders() throws {
        let classic = try JSONEncoder().encode(ClipSubtitleStyle.classic)
        var legacy = try JSONSerialization.jsonObject(with: classic) as! [String: Any]
        legacy.removeValue(forKey: "position")
        guard try JSONDecoder().decode(ClipSubtitleStyle.self, from: JSONSerialization.data(withJSONObject: legacy)).position == nil else { throw ServiceError.invalidResponse }
        var style = ClipSubtitleStyle.classic
        style.position = .init(x: 0.2, y: 0.15, width: 0.5)
        let restored = try JSONDecoder().decode(ClipSubtitleStyle.self, from: JSONEncoder().encode(style))
        let size = CGSize(width: 1920, height: 1080), box = CGSize(width: 960, height: 100)
        let point = ClipSubtitleRenderer.origin(size: size, overlay: box, style: restored)
        guard restored == style, style.valid, point.x == 0, point.y > 800,
              point.y + box.height <= size.height else { throw ServiceError.invalidResponse }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simusub-folder-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let creator = WatchedCreator(.init(platform: .bilibili, address: "https://live.bilibili.com/6", name: "主播/测试"))
        var settings = LiveMonitorSettings(); settings.outputFolder = root.path
        let output = try LiveRecordingEngine.outputURL(creator: creator, settings: settings)
        guard output.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "主播_测试-Bilibili",
              output.deletingLastPathComponent().lastPathComponent.count == 10 else { throw ServiceError.invalidResponse }
        print("v1.36: legacy style decoding, normalized position and creator/date folders passed")
    }

    static func offlineRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simusub-offline-check-" + UUID().uuidString)
        let suite = "SimuSub.offline136." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let service = Offline136Service()
        let store = LiveMonitorStore(storage: LiveMonitorStorage(root: root), service: service,
            credentials: LiveCredentials(defaults: defaults, enabled: false), notificationsEnabled: false)
        store.updateSettings { $0.outputFolder = root.appendingPathComponent("videos").path }
        store.follow(.init(platform: .youtube, address: "https://www.youtube.com/channel/UCoffline", name: "离线主播"))
        store.startRecording(store.creators[0].id)
        for _ in 0..<100 { if !store.hasActiveRecordings { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let attempts = await service.attempts
        guard attempts == 1, !store.hasActiveRecordings, store.creators[0].snapshot.state == .offline,
              store.recordings[0].state == .cancelled, store.recordings[0].savedBytes == 0 else { throw ServiceError.invalidResponse }
        await store.shutdown()
        print("v1.36: offline creator ends recording immediately without reconnect")
    }
    static func positionedVideo(media: ClipMedia, directory: URL) async throws {
        let raw = directory.appendingPathComponent("v136-position-source.mp4")
        let output = directory.appendingPathComponent("v136-position-export.mp4")
        try await ClipMediaEngine.cut(media: media, range: .init(title: "位置检查", start: 0, end: 1.5), output: raw)
        var style = ClipSubtitleStyle.classic
        style.position = .init(x: 0.3, y: 0.15, width: 0.5)
        let cue = Caption(start: 0, end: 1.5, original: "字幕は好きな位置へ", translated: "字幕可以放在这里")
        try await ClipMediaEngine.burn(input: raw, output: output, captions: [cue], style: style)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output)); generator.appliesPreferredTrackTransform = true
        let cg = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("v136-position-export.png"))
        guard LiveRecordingEngine.fileSize(output.path) > 0 else { throw ServiceError.invalidResponse }
        let store = ClipStore(root: directory.appendingPathComponent("position-store"))
        let id = try await store.importVideo(raw, outputGrouping: ["测试主播-Bilibili", "2026-11-03"])
        var range = ClipRange(title: "自定义位置", start: 0, end: 1.5); range.subtitleStyle = style
        store.update(id) { $0.captions = [cue]; $0.ranges = [range] }
        store.start(.init(projectID: id, kind: .export, ranges: [range], outputFolder: directory.appendingPathComponent("grouped-exports").path), model: nil)
        for _ in 0..<600 { if !store.isBusy { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        guard store.jobs.first?.state == .completed, let exported = store.projects.first?.exports.first,
              exported.contains("测试主播-Bilibili/2026-11-03/"),
              ClipStore(root: store.root).projects.first?.ranges.first?.style.position == style.position else { throw ServiceError.invalidResponse }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let player = AVPlayer(url: raw)
        var dragged: CGPoint?, committed = false
        window.contentView = NSHostingView(rootView: ClipStyledPlayer(player: player, captions: [cue], style: style,
            mediaSize: CGSize(width: 640, height: 360), onPosition: { point, commit in dragged = point; committed = commit }))
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 250_000_000)
        func find(_ view: NSView) -> ClipStyledPlayer.PositionView? {
            if let result = view as? ClipStyledPlayer.PositionView { return result }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let view = find(window.contentView!), view.bounds.width > 0 else { throw ServiceError.invalidResponse }
        let scale = min(view.bounds.width / 640, view.bounds.height / 360)
        let local = CGPoint(x: (view.bounds.width - 640 * scale) / 2 + 160 * scale,
                            y: (view.bounds.height - 360 * scale) / 2 + 270 * scale)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(local, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: view.convert(local, to: nil), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { throw ServiceError.invalidResponse }
        view.mouseDown(with: down); view.mouseUp(with: up)
        guard committed, let dragged, abs(dragged.x - 0.25) < 0.01, abs(dragged.y - 0.25) < 0.01 else { throw ServiceError.invalidResponse }
        print("v1.36: native drag respects video letterboxing, style persists and grouped export succeeds")

    }

}
