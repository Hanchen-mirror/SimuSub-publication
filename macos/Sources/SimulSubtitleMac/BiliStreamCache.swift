import Foundation
import CryptoKit

/// Signed stream URLs are short-lived, private cache data. Never store credentials.
final class BiliStreamCache {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimuSub/LiveStreams", isDirectory: true)
    }
    private struct Track: Codable {
        var url: URL
        var headers: [String: String]
        var video: Bool
        var audio: Bool
    }
    private struct Entry: Codable {
        var identity: String
        var session: String?
        var account: String
        var expires: Date
        var title: String
        var tracks: [Track]
    }
    private let root: URL?
    private var entries: [String: Entry] = [:]
    init(root: URL?) { self.root = root }
    private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func file(_ creator: WatchedCreator) -> URL? { root?.appendingPathComponent(digest(creator.identity) + ".json") }
    func input(for creator: WatchedCreator, cookies: String?, now: Date = Date()) -> ResolvedLiveInput? {
        guard creator.snapshot.state != .offline, creator.snapshot.state != .upcoming else { remove(creator); return nil }
        let saved = entries[creator.identity] ?? file(creator).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        guard let saved, saved.identity == creator.identity, saved.account == digest(cookies ?? "guest"),
              saved.expires > now.addingTimeInterval(30), saved.expires < now.addingTimeInterval(3_601),
              creator.snapshot.sessionID == nil || saved.session == creator.snapshot.sessionID,
              !saved.tracks.isEmpty, saved.tracks.count <= 2, saved.tracks.contains(where: \.video),
              saved.tracks.allSatisfy({ ["http", "https"].contains($0.url.scheme ?? "") && $0.url.host != nil && $0.url.user == nil && $0.url.password == nil }) else {
            remove(creator); return nil
        }
        return .init(tracks: saved.tracks.map { track in
            var headers = track.headers.filter { ["user-agent", "referer", "origin"].contains($0.key.lowercased()) }
            if let cookie = LiveCookie.header(cookies, platform: .bilibili, url: track.url) { headers["Cookie"] = cookie }
            return .init(url: track.url, headers: headers, hasVideo: track.video, hasAudio: track.audio)
        }, title: saved.title)
    }
    func save(_ input: ResolvedLiveInput, for creator: WatchedCreator, cookies: String?, now: Date = Date()) {
        guard input.browserCapture == nil, !input.tracks.isEmpty else { return }
        var expiry = now.addingTimeInterval(600)
        for track in input.tracks {
            for item in URLComponents(url: track.url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                if ["expires", "expire", "deadline", "wsTime"].contains(item.name), let value = item.value {
                    let stamp = item.name == "wsTime" ? UInt64(value, radix: 16).map(Double.init) : Double(value)
                    if let stamp { expiry = min(expiry, Date(timeIntervalSince1970: stamp)) }
                }
            }
        }
        let entry = Entry(identity: creator.identity, session: creator.snapshot.sessionID, account: digest(cookies ?? "guest"),
            expires: expiry, title: input.title, tracks: input.tracks.map {
                Track(url: $0.url, headers: $0.headers.filter { ["user-agent", "referer", "origin"].contains($0.key.lowercased()) }, video: $0.hasVideo, audio: $0.hasAudio)
            })
        entries[creator.identity] = entry
        guard let root, let file = file(creator) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entry).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Cache failure must not prevent recording. */ }
    }
    func remove(_ creator: WatchedCreator) {
        entries[creator.identity] = nil
        if let file = file(creator) { try? FileManager.default.removeItem(at: file) }
    }
}
