import Foundation
import CryptoKit

/// A saved movie and its subtitle files are separate recoverable steps.
struct ClipExportReceipt: Codable, Equatable {
    var rangeID: UUID
    var fingerprint: String
    var mediaPath: String
    var mediaBytes: Int64
    var completedSidecars: [String] = []

    var mediaExists: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: mediaPath)
        return attributes?[.type] as? FileAttributeType == .typeRegular
            && (attributes?[.size] as? NSNumber)?.int64Value == mediaBytes && mediaBytes > 0
    }
    static func fingerprint(media: ClipMedia, range: ClipRange, cues: [Caption], job: ClipJob, roles: [ClipCaptionRole] = []) throws -> String {
        struct Snapshot: Encodable {
            var media: ClipMedia
            var title: String
            var start: Double
            var end: Double
            var style: ClipSubtitleStyle
            var roundedMaskRevision: Int?
            var cueStyles: [ClipSubtitleStyle]?
            var cues: [Caption]
            var burn: Bool
            var kind: ClipExportKind
            var folder: String
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let usedRoleIDs = Set(cues.compactMap(\.clipRoleID))
        let usedRoles = roles.filter { usedRoleIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let cueStyles = usedRoles.map { role in
            var style = range.style
            style.chinese = role.chinese; style.japanese = role.japanese
            return style
        }
        let snapshot = Snapshot(media: media, title: range.title, start: range.start, end: range.end,
                                style: range.style, roundedMaskRevision: job.burnSubtitles && (range.style.mask?.enabled == true || range.style.background > 0) ? 1 : nil,
                                cueStyles: job.burnSubtitles && !cueStyles.isEmpty ? cueStyles : nil, cues: cues, burn: job.burnSubtitles,
                                kind: job.exportKind ?? .mp4, folder: job.outputFolder ?? "")
        return SHA256.hash(data: try encoder.encode(snapshot)).map { String(format: "%02x", $0) }.joined()
    }
}
