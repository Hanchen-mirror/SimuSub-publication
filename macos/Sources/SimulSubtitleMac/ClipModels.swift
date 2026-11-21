import Foundation

struct ClipMedia: Codable, Equatable {
    var path: String
    var duration: Double
    var width: Int
    var height: Int
    var hasAudio: Bool
    var bytes: Int64
    var modified: Double
    var url: URL { URL(fileURLWithPath: path) }
    func validateFile() throws {
        let a: [FileAttributeKey: Any]
        do { a = try FileManager.default.attributesOfItem(atPath: path) }
        catch { throw ClipError.message(ClipFailure.message(error, operation: "读取原视频")) }
        guard (a[.size] as? NSNumber)?.int64Value == bytes,
              abs(((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) - modified) < 0.01 else {
            throw ClipError.message("原视频已移动或被修改，请重新导入；已有字幕草稿仍保留。")
        }
    }
}
struct ClipRange: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var start: Double
    var end: Double
    var selected = true
    var reason: String?
    var proofreadCandidates: [Caption]?
    var captionEdits: [Caption]?
    var deletedCaptionIDs: [UUID]?
    var importedCaptions: [Caption]?
    var subtitleStyle: ClipSubtitleStyle?
    var generation: ClipGeneration?
    var style: ClipSubtitleStyle { subtitleStyle ?? .classic }
    var duration: Double { end - start }
    func validate(duration: Double) throws {
        guard start.isFinite, end.isFinite, duration.isFinite, start >= 0, end <= duration + 0.05,
              end > start, end - start >= min(duration, 0.2) - 0.000001 else {
            throw ClipError.message("请选择视频范围内有效的起止点。")
        }
    }
    func validateForExport(duration: Double) throws {
        try validate(duration: duration)
        guard self.duration <= 600 else {
            throw ClipError.message("单次导出支持最长 10 分钟的片段，请缩短选段。")
        }
    }
}

struct ClipGeneration: Codable, Equatable {
    var serviceKey: String
    var span: ClosedRange<Double>
    var captions: [Caption] = []
    var complete = false
}

struct ClipEnergy: Codable, Equatable { var start: Double; var rms: Double }
struct ClipCaptionRole: Identifiable, Codable, Equatable {
    var id = UUID()
    var number: Int?
    var name: String
    var chinese: ClipTextStyle
    var japanese: ClipTextStyle
}

struct ClipProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var creatorID: UUID?
    var outputGrouping: [String]?
    var media: ClipMedia
    var captions: [Caption] = []
    var captionRoles: [ClipCaptionRole]?
    var showsRoleBadges: Bool?
    var ranges: [ClipRange] = []
    var energy: [ClipEnergy] = []
    var createdAt = Date()
    var updatedAt = Date()
    var exports: [String] = []
    var posterPath: String?
    var previewPath: String?
    var previewStart: Double?
    var previewEnd: Double?
    var previewHasSubtitles: Bool?
    var previewRangeID: UUID?
    var candidates: [ClipRange]?
    var highlightsNote: String?
    var analysisCoverage: [ClosedRange<Double>] = []
    var wholeRange: ClipRange { ClipRange(title: "选段 1", start: 0, end: media.duration) }
}
enum ClipJobKind: String, Codable { case preview, transcribe, export, recommend, proofread }
enum ClipExportKind: String, Codable { case mp4, mp3 }
enum ClipJobState: String, Codable {
    case running, completed, failed, cancelled, interrupted, paused
    var title: String {
        switch self { case .running: "进行中"; case .completed: "已完成"; case .failed: "未完成"; case .cancelled: "已取消"; case .interrupted: "可重试"; case .paused: "已暂停" }
    }
}
struct ClipJob: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectID: UUID
    var kind: ClipJobKind
    var state: ClipJobState = .running
    var progress: Double = 0
    var message: String = "正在准备…"
    var range: ClipRange?
    var ranges: [ClipRange] = []
    var configuredServices = false
    var generationServiceKey: String?
    var noSpeechDetected: Bool?
    var sourceLanguage: SubtitleLanguage? = nil
    var targetLanguage: SubtitleLanguage? = nil
    var burnSubtitles = true
    var exportKind: ClipExportKind?
    var recommendationCount: Int?
    var temporaryPaths: [String]?
    var completedRanges: [UUID]?
    var exportReceipts: [ClipExportReceipt]?
    var outputFolder: String?
    var createdAt = Date()
    var showsSubtitleResultInInspector: Bool {
        kind == .transcribe && recommendationCount == nil && range != nil
            && (state == .completed || (state == .failed && noSpeechDetected == true))
    }

}
enum ClipError: LocalizedError {
    case message(String)
    case noSpeech
    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .noSpeech: "当前选段未识别到语音，请检查音轨、选段范围和源语言后重试。"
        }
    }
}
struct ClipServices: Sendable {
    var recognizer: any SpeechRecognizing
    var translator: any TextTranslating
    var sourceLanguage: SubtitleLanguage = .japanese
    var targetLanguage: SubtitleLanguage = .simplifiedChinese
}
enum ClipTime {
    static func label(_ value: Double) -> String {
        guard value.isFinite else { return "00:00:00.000" }
        let ms = Int((min(172800, max(0, value)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var result = 0.0
        for (i, part) in parts.enumerated() {
            guard let n = Double(part), n.isFinite, n >= 0, (i == 0 || n < 60) else { return nil }
            result = result * 60 + n
        }
        return result.isFinite && result <= 172800 ? result : nil
    }
    static func captions(_ all: [Caption], within range: ClipRange) -> [Caption] {
        all.filter { !$0.isDraft && $0.end > range.start && $0.start < range.end }.sorted { $0.start < $1.start }.map {
            var cue = $0; cue.start = max(0, cue.start - range.start); cue.end = min(range.duration, cue.end - range.start); return cue
        }
    }
}

extension ClipProject {
    mutating func removeCaptionRole(_ id: UUID) {
        guard var roles = captionRoles, roles.contains(where: { $0.id == id }) else { return }
        // Older projects use the position in the role list as their visible number.
        for i in roles.indices where roles[i].number == nil { roles[i].number = i + 1 }
        roles.removeAll { $0.id == id }
        captionRoles = roles

        func resetMarkers(_ cues: inout [Caption]) {
            for i in cues.indices where cues[i].clipRoleID == id { cues[i].assignClipRole(nil) }
        }
        func resetRanges(_ ranges: inout [ClipRange]) {
            for i in ranges.indices {
                if ranges[i].captionEdits != nil { resetMarkers(&ranges[i].captionEdits!) }
                if ranges[i].importedCaptions != nil { resetMarkers(&ranges[i].importedCaptions!) }
                if ranges[i].proofreadCandidates != nil { resetMarkers(&ranges[i].proofreadCandidates!) }
            }
        }
        resetMarkers(&captions)
        resetRanges(&ranges)
        if candidates != nil { resetRanges(&candidates!) }
    }

    func hasBurnableCaptions(for range: ClipRange) -> Bool {
        range.style.complete(captions(for: range))
    }

    func captions(for range: ClipRange) -> [Caption] {
        mergedCaptions(for: range).filter { $0.end > range.start && $0.start < range.end }
    }

    /// Resolve speaker changes before clipping, so trimming a range through a
    /// speaker's turn keeps the visible lines in that speaker's style.
    func styledCaptions(for range: ClipRange, inheritingAt cueID: UUID? = nil) -> [Caption] {
        let roles = Set((captionRoles ?? []).map(\.id))
        guard !roles.isEmpty else { return captions(for: range) }
        var speaker: UUID?
        var visible: [Caption] = []
        for var cue in mergedCaptions(for: range) {
            if cue.start >= range.end { break }
            if cue.id == cueID { cue.inheritClipRole() }
            if let id = cue.clipRoleID {
                speaker = roles.contains(id) ? id : nil
            } else if cue.clipUsesDefault == true {
                speaker = nil
            }
            if cue.end > range.start {
                cue.clipRoleID = speaker
                visible.append(cue)
            }
        }
        return visible
    }

    /// A speaker choice edits the marker alone, including for imported overlapping cues.
    mutating func setRoleMarker(from cue: Caption, in rangeID: UUID) {
        guard let index = ranges.firstIndex(where: { $0.id == rangeID }),
              var current = captions(for: ranges[index]).first(where: { $0.id == cue.id }) else { return }
        current.clipRoleID = cue.clipRoleID
        current.clipUsesDefault = cue.clipUsesDefault
        var edits = ranges[index].captionEdits ?? []
        if let existing = edits.firstIndex(where: { $0.id == cue.id }) { edits[existing] = current }
        else { edits.append(current) }
        ranges[index].captionEdits = edits
    }

    private func mergedCaptions(for range: ClipRange) -> [Caption] {
        var values = range.importedCaptions ?? captions
        if let generation = range.generation {
            let overlay = generation.captions.filter { cue in
                !(range.importedCaptions ?? []).contains { $0.start < cue.end && $0.end > cue.start }
                    && !(range.captionEdits ?? []).contains { $0.id != cue.id && $0.start < cue.end && $0.end > cue.start }
            }
            if range.importedCaptions == nil {
                values.removeAll { cue in
                    if generation.complete { return cue.start < generation.span.upperBound && cue.end > generation.span.lowerBound }
                    return overlay.contains { $0.end > cue.start && $0.start < cue.end }
                }
            }
            values += overlay
        }
        for cue in range.captionEdits ?? [] {
            if let i = values.firstIndex(where: { $0.id == cue.id }) { values[i] = cue }
            else { values.append(cue) }
        }
        let removed = Set(range.deletedCaptionIDs ?? [])
        return values.filter { !removed.contains($0.id) && !$0.isDraft }.sorted { $0.start < $1.start }
    }
}

extension ClipProject {
    func unrecognizedRanges(in range: ClipRange) -> [ClipRange] {
        var cursor = range.start, result: [ClipRange] = []
        for coverage in analysisCoverage.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if coverage.upperBound <= cursor || coverage.lowerBound >= range.end { continue }
            if coverage.lowerBound > cursor + 0.02 { result.append(ClipRange(title: range.title, start: cursor, end: min(range.end, coverage.lowerBound))) }
            cursor = max(cursor, coverage.upperBound)
        }
        if cursor < range.end - 0.02 { result.append(ClipRange(title: range.title, start: cursor, end: range.end)) }
        return result
    }
}
