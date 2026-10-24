import Foundation
import NaturalLanguage

/// Local, explainable suggestions. This ranks speech, reaction words, changes
/// in vocabulary and relative audio energy; it does not claim visual game-event
/// understanding or fabricate timestamps with a language model.
enum ClipHighlights {
    struct Result { var candidates: [ClipRange]; var note: String }
    private struct Proposal { var range: ClipRange; var score: Double }
    private static let reactions = ["やば", "すごい", "凄い", "えっ", "待って", "まさか", "嘘", "うそ", "本当", "びっくり", "笑", "優勝", "成功", "失敗", "初めて", "ありがとう", "可愛い", "かわいい", "最高", "哈哈", "厉害", "震惊", "真的假的", "终于", "成功", "爆笑", "太棒", "笑死"]
    static func recommend(_ project: ClipProject, maximum: Int = 5) -> Result {
        let duration = project.media.duration
        let captions = project.captions.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.05 && !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.start < $1.start }
        guard duration.isFinite, duration > 0, !captions.isEmpty else { return Result(candidates: [], note: "先生成日中字幕，才能根据语句推荐高光。") }
        let tokens = captions.map { words($0.original + " " + $0.translated) }
        let allEnergy = project.energy.filter { $0.rms.isFinite && $0.rms > 0.0001 }.map(\.rms).sorted()
        let median = allEnergy.isEmpty ? 0 : allEnergy[allEnergy.count / 2]
        let loudThreshold = allEnergy.isEmpty ? Double.infinity : max(0.005, allEnergy[min(allEnergy.count - 1, Int(Double(allEnergy.count) * 0.8))], median * 1.35)
        var proposals: [Proposal] = []
        for (index, cue) in captions.enumerated() {
            let scope = project.analysisCoverage.filter { $0.contains((cue.start + cue.end) / 2) }
                .max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) } ?? 0...duration
            let lower = max(0, scope.lowerBound), upper = min(duration, scope.upperBound)
            var first = index, last = index
            while first > 0, cue.start - captions[first - 1].start < 10,
                  captions[first].start - captions[first - 1].end < 5, captions[first - 1].start >= lower { first -= 1 }
            while last + 1 < captions.count, captions[last + 1].end - cue.end < 17,
                  captions[last + 1].start - captions[last].end < 5, captions[last + 1].end <= upper { last += 1 }
            var start = max(lower, captions[first].start - 1.2), end = min(upper, captions[last].end + 1.5)
            if end - start < 12 {
                let extra = (12 - (end - start)) / 2
                start = max(lower, start - extra); end = min(upper, end + extra)
            }
            guard end > start, end - start <= 90, start <= cue.start, end >= cue.end else { continue }
            let text = cue.original + cue.translated
            let hits = reactions.filter { text.localizedCaseInsensitiveContains($0) }
            let localEnergy = project.energy.filter { $0.start >= cue.start - 1 && $0.start < cue.end + 1 && $0.rms.isFinite }
            let peak = localEnergy.map(\.rms).max() ?? 0
            let loudness = peak >= loudThreshold ? min(2, peak / max(median, 0.001)) / 2 : 0
            let prior = (max(0, index - 8)..<index).filter { cue.start - captions[$0].end <= 60 }.reduce(into: Set<String>()) { $0.formUnion(tokens[$1]) }
            let novelty = prior.count >= 4 && tokens[index].count >= 2 ? Double(tokens[index].subtracting(prior).count) / Double(tokens[index].count) : 0
            let activity = Double(captions[first...last].reduce(0) { $0 + $1.original.count }) / max(1, end - start)
            let score = min(2.4, Double(hits.count) * 0.8) + loudness * 1.3 + novelty * 0.65 + min(0.7, activity / 10) + 0.1
            var reasons: [String] = []
            if !hits.isEmpty { reasons.append("反应词：" + hits.prefix(2).joined(separator: "、")) }
            if loudness > 0 { reasons.append(String(format: "音量约为常态 %.1f 倍", peak / max(median, 0.001))) }
            if novelty > 0.65 { reasons.append("语句关键词出现变化") }
            if activity > 3.5 { reasons.append("对话较密集") }
            if reasons.isEmpty { reasons.append("完整语句与前后文，适合人工预览") }
            let titleText = (cue.translated.isEmpty ? cue.original : cue.translated).replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(titleText.prefix(28)) + (titleText.count > 28 ? "…" : "")
            let range = ClipRange(title: title.isEmpty ? "高光候选" : title, start: start, end: end, selected: false, reason: reasons.joined(separator: " · "))
            proposals.append(Proposal(range: range, score: score))
        }
        var chosen: [ClipRange] = []
        for p in proposals.sorted(by: { $0.score == $1.score ? $0.range.start < $1.range.start : $0.score > $1.score }) {
            guard !chosen.contains(where: { overlap($0, p.range) > 0.15 }) else { continue }
            chosen.append(p.range)
            if chosen.count >= min(8, max(1, maximum)) { break }
        }
        chosen.sort { $0.start < $1.start }
        let analyzed = coverage(project.analysisCoverage, duration: duration)
        let coverageNote = project.analysisCoverage.isEmpty ? "基于当前字幕" : String(format: "已分析视频的 %.0f%%", analyzed / duration * 100)
        return Result(candidates: chosen, note: coverageNote + "；候选基于语句、反应词与音量变化，请预览确认。纯视觉游戏事件暂不分析。")
    }
    static func coverage(_ spans: [ClosedRange<Double>], duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let sorted = spans.filter { $0.lowerBound.isFinite && $0.upperBound.isFinite }.map { min(duration, max(0, $0.lowerBound))...min(duration, max(0, $0.upperBound)) }.sorted { $0.lowerBound < $1.lowerBound }
        var result = 0.0, end = 0.0
        for span in sorted { if span.upperBound > end { result += span.upperBound - max(end, span.lowerBound); end = span.upperBound } }
        return min(duration, max(0, result))
    }
    private static func overlap(_ a: ClipRange, _ b: ClipRange) -> Double {
        max(0, min(a.end, b.end) - max(a.start, b.start)) / max(0.1, min(a.duration, b.duration))
    }
    private static func words(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
        var words = Set<String>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).lowercased()
            if word.count >= 2 && word.unicodeScalars.contains(where: CharacterSet.letters.contains) { words.insert(word) }
            return true
        }
        return words
    }
}
