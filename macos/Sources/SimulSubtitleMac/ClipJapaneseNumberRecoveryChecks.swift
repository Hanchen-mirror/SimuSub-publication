import Foundation

enum ClipJapaneseNumberRecoveryChecks {
    static func run() throws -> [String] {
        typealias Token = RecognizedSpeech.Token
        func speech(_ text: String, _ times: [Double]) -> RecognizedSpeech {
            .init(text: text, tokens: zip(text, times).map { Token(text: String($0), time: $1) })
        }
        func numbers(_ first: RecognizedSpeech, _ other: RecognizedSpeech) -> [String] {
            ClipJapaneseNumberRecovery.agreement(first, start: 0, duration: 9,
                second: other, otherStart: 0, otherDuration: 9, owned: 0..<9, limit: 9).map(\.text)
        }
        var checks: [String] = []
        func check(_ passed: Bool, _ name: String) throws {
            guard passed else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name)
        }
        let beats = [0.4, 0.72, 0.94, 1.57, 1.79, 2.15]
        let first = speech("と一八一八ね", beats)
        let second = speech("や１８１８な", beats.map { $0 + 0.04 })
        try check(numbers(first, second) == ["18", "18"], "ctc_number_preserves_repeated_digit_groups_across_prose_and_scripts")
        let distant = speech(second.text, beats.map { $0 + 0.25 })
        try check(numbers(first, distant).isEmpty, "ctc_number_requires_per_digit_time_agreement")
        let changed = speech("や１８１９な", beats)
        try check(numbers(first, changed).isEmpty, "ctc_number_does_not_reconstruct_a_missing_repetition")
        let uniform = speech("1818", [1, 1.25, 1.50, 1.75])
        try check(numbers(uniform, uniform) == ["1818"], "ctc_number_does_not_split_a_continuous_identifier")
        let part = speech("ね６８３２６３", [0.2, 1.2, 1.4, 1.6, 1.8, 2.4, 2.6])
        let full = speech("え68326832", [0.3, 1.22, 1.42, 1.62, 1.82, 2.42, 2.62, 2.82, 3.02])
        try check(numbers(part, full) == ["6832"], "ctc_number_keeps_only_the_fully_heard_copy")
        let interior = speech("683", [1.22, 1.42, 1.82])
        let correct = speech("6893", [1.22, 1.42, 1.62, 1.82])
        func retry(_ a: RecognizedSpeech, _ b: RecognizedSpeech) -> Bool {
            !ClipJapaneseNumberRecovery.disputedGroups(a, start: 0, duration: 9,
                second: b, otherStart: 0, otherDuration: 9, owned: 0..<9).isEmpty
        }
        try check(retry(correct, interior) && retry(interior, correct),
                  "ctc_number_reviews_single_internal_omission_with_matched_endpoints")
        try check(!retry(correct, speech("683", [1.22, 1.42, 2.23])) && !retry(correct, correct),
                  "ctc_number_avoids_extra_decode_for_mismatched_or_identical_groups")
        for text in ["1818円", "1818%", "-1818", "1818.9", "R1818", "1818年", "1818号"] {
            let times = Array((0..<text.count).map { 1 + Double($0) * 0.22 })
            let value = speech(text, times)
            try check(numbers(value, value).isEmpty, "ctc_number_preserves_attached_notation_" + text)
        }
        let one = speech("九", [2.6]), arabic = speech("9", [2.64])
        try check(numbers(one, arabic) == ["9"], "ctc_number_accepts_acoustically_isolated_digit")
        let homophone = speech("地号九九", [1, 1.22, 1.44, 1.72])
        try check(numbers(homophone, homophone).isEmpty, "ctc_number_does_not_convert_homophones_to_digits")
        let malformed = RecognizedSpeech(text: "1818", tokens: [Token(text: "8", time: .nan)])
        try check(numbers(malformed, first).isEmpty, "ctc_number_rejects_malformed_decoder_timing")
        return checks
    }
}
