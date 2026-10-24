import Foundation

@MainActor
enum ClipHighlightChecks {
    static func run(media: ClipMedia) throws -> [String] {
        var checks: [String] = []
        func require(_ value: Bool, _ name: String) throws {
            guard value else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        var media = media; media.duration = 360
        var project = ClipProject(name: "高光检查", media: media)
        try require(ClipHighlights.recommend(project).candidates.isEmpty, "highlights_no_hallucinated_candidates_without_transcript")
        for n in 0..<24 {
            let start = Double(n) * 15
            let reaction = [6, 13, 20].contains(n)
            project.captions.append(Caption(start: start, end: start + 5, original: reaction ? "えっ、まさか！すごい！優勝した！" : "今日は配信の予定について話します。", translated: reaction ? "太棒了！我们终于赢了！" : "今天聊一聊直播安排。"))
        }
        project.energy = (0..<360).map { .init(start: Double($0), rms: [91, 196, 301].contains($0) ? 0.15 : 0.02) }
        project.analysisCoverage = [0...360]
        let result = ClipHighlights.recommend(project, maximum: 3)
        try require(result.candidates.count == 3, "highlights_respect_requested_maximum")
        try require(result.candidates.allSatisfy { $0.start >= 0 && $0.end <= 360 && $0.duration <= 90 && $0.duration > 0 }, "highlights_media_times_never_escape_source")
        try require(result.candidates.allSatisfy { ($0.reason ?? "").contains("反应词") && !$0.title.isEmpty && !$0.selected }, "highlights_reaction_titles_reasons_and_explicit_selection")
        try require(zip(result.candidates, result.candidates.dropFirst()).allSatisfy { $0.0.end <= $0.1.start }, "highlights_nonoverlapping_candidates")
        try require(result.note.contains("100%") && result.note.contains("纯视觉"), "highlights_coverage_and_method_honest_in_ui")
        let eight = ClipHighlights.recommend(project, maximum: 50)
        try require(eight.candidates.count <= 8 && Set(eight.candidates.map { ClipTime.label($0.start) }).count == eight.candidates.count, "highlights_limit_and_duplicate_suppression")
        var partial = project
        partial.captions = [Caption(start: 105, end: 111, original: "すごい！", translated: "厉害！"), Caption(start: 205, end: 211, original: "優勝！", translated: "赢了！")]
        partial.analysisCoverage = [100...120, 200...220]
        let limited = ClipHighlights.recommend(partial)
        try require(limited.candidates.count == 2 && limited.candidates.allSatisfy { r in partial.analysisCoverage.contains { $0.contains(r.start) && $0.contains(r.end) } }, "highlights_respect_partial_analysis_boundaries_and_gaps")
        try require(ClipHighlights.coverage([0...50, 20...60, 100...110], duration: 200) == 70, "highlights_analysis_coverage_merges_overlaps")
        try require(ClipHighlights.coverage([-20...10, 300...400], duration: 200) == 10, "highlights_coverage_clamps_outside_ranges")
        var silent = project; silent.captions = []; silent.energy = [.init(start: 1, rms: 1)]
        try require(ClipHighlights.recommend(silent).candidates.isEmpty, "highlights_loud_music_alone_not_misrepresented_as_speech_highlight")
        return checks
    }
}
