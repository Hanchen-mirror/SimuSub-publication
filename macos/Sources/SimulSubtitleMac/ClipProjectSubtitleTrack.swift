import Foundation

extension ClipProject {
    /// Subtitle timestamps stay in source-media time. The project ID gives jobs
    /// and editors a stable target even when the last export range is removed.
    var subtitleRange: ClipRange {
        subtitleTrack ?? ClipRange(id: id, title: "完整视频", start: 0, end: media.duration)
    }

    mutating func migrateLegacySubtitleTrack() {
        guard subtitleTrack == nil else { return }
        let old = ranges.filter {
            $0.generation != nil || $0.importedCaptions != nil || $0.captionEdits != nil
                || $0.deletedCaptionIDs != nil || $0.proofreadCandidates != nil
        }
        guard !old.isEmpty else { return }
        var track = subtitleRange
        if old.count == 1, let only = old.first, only.start == 0, only.end == media.duration {
            track.generation = only.generation
            track.importedCaptions = only.importedCaptions
            track.captionEdits = only.captionEdits
            track.deletedCaptionIDs = only.deletedCaptionIDs
            track.proofreadCandidates = only.proofreadCandidates
            track.subtitleStyle = ranges.count == 1 ? only.subtitleStyle : nil
            subtitleTrack = track
            return
        }

        // Imported files were stored in full on each importing range. Keep
        // absolute cues outside those ranges, including files imported twice.
        var imports: [ImportKey: UUID] = [:]
        var aliases: [UUID: UUID] = [:]
        var manual: [UUID: Caption] = [:]
        var suggestions: [UUID: Caption] = [:]
        var removed = Set<UUID>()
        var generated = Dictionary(captions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for range in old {
            if let generation = range.generation {
                if generation.complete {
                    generated = generated.filter { _, cue in cue.end <= generation.span.lowerBound || cue.start >= generation.span.upperBound }
                }
                for cue in generation.captions { generated[cue.id] = cue }
            }
        }
        var replacedSpans: [Range<Double>] = []
        for range in old {
            if let imported = range.importedCaptions {
                if range.end > range.start { replacedSpans.append(range.start..<range.end) }
                for cue in imported {
                    if cue.end > cue.start { replacedSpans.append(cue.start..<cue.end) }
                    let key = ImportKey(cue)
                    if let previous = imports[key] { aliases[cue.id] = previous }
                    else { imports[key] = cue.id; manual[cue.id] = cue }
                }
            }
        }
        // A saved manual correction wins over another range's deletion. For
        // conflicting edits of the same ID, the later stored range wins.
        var explicitEdits = Set<UUID>()
        for range in old {
            for var cue in range.captionEdits ?? [] {
                cue.id = aliases[cue.id] ?? cue.id
                manual[cue.id] = cue
                explicitEdits.insert(cue.id)
            }
            for var cue in range.proofreadCandidates ?? [] {
                cue.id = aliases[cue.id] ?? cue.id
                suggestions[cue.id] = cue
            }
            for cueID in range.deletedCaptionIDs ?? [] { removed.insert(aliases[cueID] ?? cueID) }
        }
        removed.subtract(explicitEdits)
        // Suppress stale ASR under an imported track, even when another
        // saved range carries a copy of the same ASR or a different cue ID.
        var spans: [Range<Double>] = []
        for span in replacedSpans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = spans.last, last.upperBound >= span.lowerBound {
                spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else { spans.append(span) }
        }
        var spanIndex = 0
        captions = Self.inSourceOrder(generated.values).filter { cue in
            while spanIndex < spans.count && spans[spanIndex].upperBound <= cue.start { spanIndex += 1 }
            return spanIndex == spans.count || spans[spanIndex].lowerBound >= cue.end
        }
        track.captionEdits = manual.isEmpty ? nil : Self.inSourceOrder(manual.values)
        track.proofreadCandidates = suggestions.isEmpty ? nil : Self.inSourceOrder(suggestions.values)
        track.deletedCaptionIDs = removed.isEmpty ? nil : removed.sorted { $0.uuidString < $1.uuidString }
        subtitleTrack = track
    }

    private static func inSourceOrder(_ values: Dictionary<UUID, Caption>.Values) -> [Caption] {
        values.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private struct ImportKey: Hashable {
        let start: Double, end: Double
        let source: String, translation: String
        let from: SubtitleLanguage, to: SubtitleLanguage
        let role: UUID?
        let usesDefault: Bool?
        init(_ cue: Caption) {
            start = cue.start; end = cue.end
            source = cue.original; translation = cue.translated
            from = cue.sourceLanguage; to = cue.targetLanguage
            role = cue.clipRoleID; usesDefault = cue.clipUsesDefault
        }
    }
}
