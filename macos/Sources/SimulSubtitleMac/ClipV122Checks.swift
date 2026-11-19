import Foundation
import SwiftUI

private final class ReviewURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
}
/// Endless bytes keep an inactivity timer alive; the configured wall deadline must still expire.
private final class DrippingReviewProtocol: URLProtocol {
    private var tick: Timer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            client?.urlProtocol(self, didLoad: Data([32]))
        }
    }
    override func stopLoading() { tick?.invalidate(); tick = nil }
}

private actor ContextProbe: TextTranslating {
    var contexts: [SubtitleTranslationContext] = []
    var texts: [String] = []
    let failAt: Int?
    nonisolated let requiresFullUtterance: Bool
    init(failAt: Int? = nil, requiresFullUtterance: Bool = false) { self.failAt = failAt; self.requiresFullUtterance = requiresFullUtterance }
    func translate(_ text: String, from source: String, to target: String) async throws -> String { throw ClipError.message("Context-free path used") }
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        contexts.append(context); texts.append(text)
        if texts.count == failAt { throw URLError(.timedOut) }
        return "核对：" + text
    }
}
private struct OrphanedYearRecognizer: SpeechRecognizing {
    func recognize(samples: [Float]) async throws -> String { "by 25 to 30 years." }
}
private struct DraftRecognizer: SpeechRecognizing {
    func recognize(samples: [Float]) async throws -> String { "今日は歌枠です" }
}
private struct ForbiddenRecognizer: SpeechRecognizing {
    func recognize(samples: [Float]) async throws -> String { throw ClipError.message("Review must never call ASR") }
}
@MainActor
enum ClipV122Checks {
    static func run(fixture: URL, directory: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        let terms = try VTuberGlossary.parse("歌枠 = 歌回\n火羽ひのめ = 火羽ひのめ")
        try require(terms.count == 2 && VTuberGlossary.matching(terms, text: "今日は歌枠です").count == 1, "v122_glossary_sends_only_matching_terms")
        for invalid in ["a", "a=b\na=c", "=中文", "日语=", String(repeating: "x", count: 41)+"=a"] {
            do { _ = try VTuberGlossary.parse(invalid); throw ClipError.message("invalid glossary accepted") }
            catch { try require(error.localizedDescription != "invalid glossary accepted", "v122_glossary_rejects_invalid_" + String(checks.count)) }
        }
        try require(try VTuberGlossary.parse("").isEmpty, "v122_glossary_can_be_cleared")
        let probe = ContextProbe()
        _ = try await GlossaryTranslator(base: probe, terms: terms).translate("歌枠", from: "ja", to: "zh", context: .init(following: ["後文"]))
        let captured = await probe.contexts
        try require(captured[0].terms.count == 1 && captured[0].following == ["後文"], "v122_glossary_wrapper_preserves_context")
        try require(SpeechAudioFrontend.draftInterval(for: 24_000) == 24_000 && SpeechAudioFrontend.draftInterval(for: 320_000) == 64_000, "v122_drafts_keep_first_latency_and_bound_repeated_work")
        let conservative = ContextProbe(requiresFullUtterance: true)
        let localWrapper = GlossaryTranslator(base: conservative, terms: terms)
        _ = try await localWrapper.translate("それです", from: "ja", to: "zh", context: .init(previous: [.init(original: "今日は歌枠です", translated: "歌回")]))
        let localContexts = await conservative.contexts
        try require(localWrapper.requiresFullUtterance && localContexts[0].terms.isEmpty && localContexts[0].previous.count == 1,
                    "v123_local_context_kept_without_injecting_absent_terms")
        let nearby = ContextProbe()
        _ = try await GlossaryTranslator(base: nearby, terms: terms).translate("それです", from: "ja", to: "zh", context: .init(previous: [.init(original: "今日は歌枠です", translated: "歌回")]))
        let nearbyContext = await nearby.contexts
        try require(nearbyContext[0].terms == [terms[0]], "v122_glossary_retrieves_terms_from_recent_context")
        let keyProbe = ContextProbe()
        let keyWrapper = GlossaryTranslator(base: keyProbe, terms: terms)
        let keyHistory = SubtitleTranslationContext(previous: [.init(original: "Rotate the CRYPTO KEYS.", translated: "轮换密钥。")])
        for phrase in ["Rotate the CRYPTO KEYS.", "Revoke the cryptographic key.", "Crypto and cryptocurrency prices fell.", "Crypto keyboards are on sale."] {
            _ = try await keyWrapper.translate(phrase, from: "en", to: "zh", context: keyHistory)
        }
        let keyTerms = await keyProbe.contexts.map { $0.terms.map(\.chinese) }
        try require(keyTerms == [["加密密钥"], ["加密密钥"], [], []], "english_key_terms_match_only_current_whole_phrase")
        let draftProbe = ContextProbe()
        let draftModel = AppModel(defaults: UserDefaults(suiteName: "SimuSub.DraftChecks." + UUID().uuidString)!,
            modelStore: LocalModelStore(root: directory.appendingPathComponent("no-models")), recognizer: DraftRecognizer(), translator: draftProbe)
        draftModel.stablePrefixesEnabled = false
        let draftID = UUID(), audio = [Float](repeating: 0.1, count: 16_000)
        for revision in 1...3 { await draftModel.process(audio, start: 2, id: draftID, revision: revision, isFinal: false) }
        let beforeFinal = await draftProbe.texts
        try require(beforeFinal.isEmpty && draftModel.captions.count == 1 && draftModel.captions[0].isDraft, "v122_three_japanese_drafts_make_zero_translation_requests")
        await draftModel.process(audio, start: 2, id: draftID, revision: 4, isFinal: true)
        await draftModel.process(audio, start: 2, id: draftID, revision: 4, isFinal: true)
        let afterFinal = await draftProbe.texts
        try require(afterFinal.count == 1 && !draftModel.captions[0].isDraft, "v122_final_translates_once_and_duplicate_revision_is_ignored")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReviewURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel(); ReviewURLProtocol.handler = nil }
        let cloud = OpenAICompatibleTranslator(profile: .deepSeek, apiKey: "test-not-a-secret", session: session)
        var validRequest = false
        ReviewURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: ReviewURLProtocol.body(request)) as! [String: Any]
            let text = String(data: ReviewURLProtocol.body(request), encoding: .utf8)!
            validRequest = request.url?.absoluteString == "https://api.deepseek.com/chat/completions"
                && body["model"] as? String == "deepseek-flash"
                && (body["thinking"] as? [String: String])?["type"] == "disabled"
                && body["stream"] as? Bool == false
                && text.contains("前文") && text.contains("後文") && text.contains("歌回")
                && !text.contains("audio") && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-not-a-secret"
            return (200, Data(#"{"choices":[{"message":{"content":"歌回开始了","reasoning_content":"private reasoning"},"finish_reason":"stop"}]}"#.utf8))
        }
        let result = try await cloud.translate("歌枠", from: "ja", to: "zh", context: .init(previous: [.init(original: "前文", translated: "前文")], following: ["後文"], terms: terms))
        try require(validRequest && result == "歌回开始了", "v122_deepseek_official_request_context_text_only_and_content_response")
        var customProfile = ServiceProfile.deepSeek
        customProfile.translationPrompt = "这是 FF11 直播，不要省略否定。"
        var promptCalls = 0
        ReviewURLProtocol.handler = { request in
            promptCalls += 1
            let object = try JSONSerialization.jsonObject(with: ReviewURLProtocol.body(request)) as! [String: Any]
            let messages = object["messages"] as! [[String: String]]
            guard messages.first?["role"] == "system", messages.first?["content"] == customProfile.translationPrompt,
                  messages.last?["role"] == "user", messages.last?["content"]?.contains("行きません") == true else {
                throw ClipError.message("Custom prompt missing or mixed into source")
            }
            return (200, Data(#"{"choices":[{"message":{"content":"不去"},"finish_reason":"stop"}]}"#.utf8))
        }
        let custom = OpenAICompatibleTranslator(profile: customProfile, apiKey: "test-only", session: session)
        _ = try await custom.translate("行きません", from: "ja", to: "zh")
        _ = try await custom.translate("行きません", from: "ja", to: "zh", context: .init(isStablePrefix: true))
        try require(promptCalls == 2, "v124_custom_prompt_sent_in_final_and_prefix_with_one_request_each")
        let yearSuite = "SimuSub.OrphanedYearChecks." + UUID().uuidString
        let yearDefaults = UserDefaults(suiteName: yearSuite)!
        defer { yearDefaults.removePersistentDomain(forName: yearSuite) }
        yearDefaults.set("en", forKey: "subtitle.sourceLanguage.v141")
        yearDefaults.set("zh-Hans", forKey: "subtitle.targetLanguage.v141")
        ReviewURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"25至30歲。"},"finish_reason":"stop"}]}"#.utf8))
        }
        for host in ["https://api.deepseek.com", "https://compatible.invalid/v1"] {
            var profile = ServiceProfile.deepSeek
            profile.baseURL = host
            let fixture = OpenAICompatibleTranslator(profile: profile, apiKey: "test-only", session: session)
            let yearModel = AppModel(defaults: yearDefaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("no-models")),
                                     recognizer: OrphanedYearRecognizer(), translator: fixture)
            await yearModel.process([Float](repeating: 0.1, count: 16_000), start: 0)
            try require(yearModel.captions.first?.translated == "25到30年。",
                        profile.isDeepSeek ? "deepseek_orphan_duration_repaired_before_publication" : "compatible_orphan_duration_repaired_before_publication")
        }
        var earlyTimeout = 0.0
        ReviewURLProtocol.handler = { request in
            earlyTimeout = request.timeoutInterval
            return (200, Data(#"{"choices":[{"message":{"content":"提前译文"},"finish_reason":"stop"}]}"#.utf8))
        }
        _ = try await cloud.translate("歌枠です", from: "ja", to: "zh", context: .init(isStablePrefix: true))
        try require(earlyTimeout == 4, "v123_cloud_prefix_short_timeout_does_not_use_full_minute")
        let slowConfig = URLSessionConfiguration.ephemeral
        slowConfig.protocolClasses = [DrippingReviewProtocol.self]
        let slowSession = URLSession(configuration: slowConfig)
        defer { slowSession.invalidateAndCancel() }
        for host in ["https://api.deepseek.com", "https://compatible.invalid/v1"] {
            var slowProfile = ServiceProfile.deepSeek
            slowProfile.baseURL = host
            slowProfile.timeoutSeconds = 1
            let slow = OpenAICompatibleTranslator(profile: slowProfile, apiKey: "fixture", session: slowSession)
            let clock = ContinuousClock(), started = clock.now
            var timedOut = false
            do { _ = try await slow.translate("The doors will not open.", from: "en", to: "zh") }
            catch let error as URLError { timedOut = error.code == .timedOut }
            let elapsed = started.duration(to: clock.now)
            try require(timedOut && elapsed >= .milliseconds(800) && elapsed < .seconds(4),
                        slowProfile.isDeepSeek ? "deepseek_streaming_bytes_obeys_total_final_deadline" : "compatible_streaming_bytes_obeys_total_final_deadline")
        }
        for status in [401,402,404,429,503] {
            var calls = 0
            ReviewURLProtocol.handler = { _ in calls += 1; return (status, Data("secret_key source text".utf8)) }
            do { _ = try await cloud.translate("test", from: "ja", to: "zh"); throw ClipError.message("unexpected success") }
            catch {
                try require(error is ServiceError && !error.localizedDescription.contains("secret_key") && calls == 1, "v122_cloud_\(status)_safe_error_no_retry_loop")
            }
        }
        ReviewURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await cloud.translate("test", from: "ja", to: "zh"); throw ClipError.message("unexpected success") }
        catch { try require(ClipFailure.message(error, operation: "核对").contains("API-TIMEOUT"), "v122_cloud_timeout_has_actionable_message") }
        ReviewURLProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":"不完整"},"finish_reason":"length"}]}"#.utf8)) }
        do { _ = try await cloud.translate("test", from: "ja", to: "zh"); throw ClipError.message("unexpected success") }
        catch { try require(error is LocalLlamaError, "v122_cloud_truncated_output_not_saved_as_complete") }
        ReviewURLProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":null,"reasoning_content":"not a subtitle"},"finish_reason":"stop"}]}"#.utf8)) }
        do { _ = try await cloud.translate("test", from: "ja", to: "zh"); throw ClipError.message("unexpected success") }
        catch { try require(error is ServiceError, "v122_cloud_reasoning_only_not_displayed_as_subtitle") }
        let store = ClipStore(root: directory.appendingPathComponent("v122-context"))
        let id = try await store.importVideo(fixture)
        let range = ClipRange(title: "上下文", start: 0, end: 8)
        let cues = [Caption(start: 0.1, end: 1, original: "今日は歌枠です", translated: "旧一"),
                    Caption(start: 2, end: 3, original: "それは違う", translated: "旧二"),
                    Caption(start: 4, end: 5, original: "また明日", translated: "旧三")]
        store.update(id) { $0.ranges = [range]; $0.captions = cues }
        func wait() async throws {
            for _ in 0..<200 { if !store.isBusy { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            throw ClipError.message("v122 job timeout")
        }
        let review = ContextProbe()
        store.start(ClipJob(projectID: id, kind: .proofread, range: range), model: nil, services: ClipServices(recognizer: ForbiddenRecognizer(), translator: review))
        try await wait()
        let contexts = await review.contexts
        try require(store.jobs[0].state == .completed && contexts.count == 3 && contexts[1].previous.first?.original == cues[0].original && contexts[1].following == [cues[2].original], "v122_review_receives_chronological_before_and_after")
        try require(contexts[0].previous.isEmpty && contexts[2].following.isEmpty && store.projects[0].captions == cues, "v122_review_edges_and_originals_preserved")
        let failing = ContextProbe(failAt: 2)
        store.start(ClipJob(projectID: id, kind: .proofread, range: range), model: nil, services: ClipServices(recognizer: ForbiddenRecognizer(), translator: failing))
        try await wait()
        try require(store.jobs[0].state == .failed && store.jobs[0].message.contains("API-TIMEOUT") && store.projects[0].ranges[0].proofreadCandidates?.count == 1, "v122_failed_review_preserves_completed_suggestions")
        let restored = ClipStore(root: directory.appendingPathComponent("v122-context"))
        try require(restored.projects[0].ranges[0].proofreadCandidates?.count == 1 && restored.projects[0].captions == cues, "v122_partial_review_survives_restart_without_overwriting_original")
        let suite = "SimuSub.V122Checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("no-models")))
        try model.saveGlossary("歌枠 = 歌回")
        let reopened = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("no-models")))
        try require(reopened.glossary == [.init(japanese: "歌枠", chinese: "歌回")], "v122_glossary_persists_across_model_restart")
        model.selectedTranslationProfileID = model.profiles.first { $0.isDeepSeek }?.id
        try require(!model.readinessIssues.contains { $0.contains("本地翻译") }, "v122_cloud_selection_does_not_require_local_translation_model")
        try await ClipV120Checks.snapshot(SettingsWindow().environmentObject(model).environmentObject(model.permissions).environmentObject(HomeAppearance(defaults: UserDefaults(suiteName: "SimuSub.ClipThemeChecks." + UUID().uuidString)!, backgroundFile: directory.appendingPathComponent("no-wallpaper.png"))).preferredColorScheme(.dark), size: CGSize(width: 780, height: 900), output: directory.appendingPathComponent("v122-subtitle-settings.png"))
        try require(true, "v122_native_glossary_and_translation_settings_rendered")
        return checks
    }
}
