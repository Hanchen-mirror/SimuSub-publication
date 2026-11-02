import Foundation
import SwiftUI

struct VTuberTerm: Codable, Equatable, Sendable {
    let japanese: String
    let chinese: String
}
enum VTuberGlossary {
    static let defaults: [VTuberTerm] = [
        .init(japanese: "雑談", chinese: "闲聊"), .init(japanese: "歌枠", chinese: "歌回"),
        .init(japanese: "切り抜き", chinese: "切片"), .init(japanese: "スパチャ", chinese: "付费留言"),
        .init(japanese: "初見", chinese: "第一次来看的观众"), .init(japanese: "同時視聴", chinese: "同步观看"),
        .init(japanese: "耐久配信", chinese: "耐久直播"), .init(japanese: "メンバーシップ", chinese: "频道会员")
    ]
    static func render(_ terms: [VTuberTerm]) -> String { terms.map { "\($0.japanese) = \($0.chinese)" }.joined(separator: "\n") }
    static func parse(_ text: String) throws -> [VTuberTerm] {
        guard text.utf8.count <= 32_768 else { throw ClipError.message("术语库过长，请保留最多 100 条术语。") }
        var result: [VTuberTerm] = [], seen = Set<String>()
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            let pair = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty, pair[0].count <= 40, pair[1].count <= 60,
                  !pair.joined().unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(pair[0].precomposedStringWithCompatibilityMapping).inserted else {
                throw ClipError.message("第 \(index + 1) 行无效或日语词重复，请按「日语 = 中文」填写（分别最多 40 / 60 字）。")
            }
            result.append(.init(japanese: pair[0], chinese: pair[1]))
        }
        guard result.count <= 100 else { throw ClipError.message("最多保存 100 条术语。") }
        return result
    }
    static func matching(_ terms: [VTuberTerm], text: String) -> [VTuberTerm] {
        let normalized = text.precomposedStringWithCompatibilityMapping
        return Array(terms.filter { normalized.contains($0.japanese.precomposedStringWithCompatibilityMapping) }
            .sorted { $0.japanese.count > $1.japanese.count }.prefix(8))
    }
}
struct GlossaryTranslator: TextTranslating {
    var requiresFullUtterance: Bool { base.requiresFullUtterance }
    let base: any TextTranslating
    let terms: [VTuberTerm]
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translate(text, from: source, to: target, context: .init())
    }
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        var enriched = context
        // Bound term retrieval to the current utterance and neighboring source text.
        // The complete personal dictionary is never sent to the cloud.
        let neighborhood = ([text] + context.previous.suffix(2).map(\.original) + context.following.prefix(1)).joined(separator: "\n")
        enriched.terms = VTuberGlossary.matching(terms, text: base.requiresFullUtterance ? text : neighborhood)
        return try await base.translate(text, from: source, to: target, context: enriched)
    }
}
struct VTuberGlossaryEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var status = ""
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 10) {
            Text("本地 VTuber 术语库").font(.headline)
            Text("每行「日语 = 中文」。可添加主播名、游戏名和常用梗。用于本地识别热词、翻译与核对。热词是识别提示，不强行替换原文；模型不支持的字会提示跳过。")
                .font(.caption).foregroundStyle(ThemeColor.muted)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 145)
                .accessibilityIdentifier("settings.glossary.editor")
            HStack {
                Button("保存术语库") {
                    do { try model.saveGlossary(text); status = "已保存；下次启动字幕或核对时生效。" }
                    catch { status = error.localizedDescription }
                }.disabled(model.isBusy)
                Button("载入默认词条") { text = VTuberGlossary.render(VTuberGlossary.defaults); status = "默认词条已填入，点击保存后生效。" }.disabled(model.isBusy)
            }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
        }.padding(18).background(ThemeColor.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .onAppear { text = VTuberGlossary.render(model.glossary) }
    }
}
