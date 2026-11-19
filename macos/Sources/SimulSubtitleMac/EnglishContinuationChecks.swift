import Foundation

enum EnglishContinuationChecks {
    static func run() throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name)
            print("CHECK: " + name)
        }
        func plan(_ left: String, _ right: String, displayed: String? = "先前的译文。",
                  source: String = "en", target: String = "zh", stable: Bool = false) -> EnglishSubtitleContinuation? {
            var context = SubtitleTranslationContext(isStablePrefix: stable)
            context.adjacentEnglishSource = left
            context.adjacentEnglishTranslation = displayed
            return EnglishSubtitleContinuation.plan(current: right, source: source, target: target, context: context)
        }
        try require(plan("The islands trail the mainland", "by eight years.")
                    == .continueTranslation(source: "The islands trail the mainland by eight years.", prefix: "先前的译文"),
                    "continuation_uses_only_confirmed_target_prefix")
        try require(plan("Styles in the West could lag behind.", "by 25 to 30 years.")
                    == .continueTranslation(source: "Styles in the West could lag behind by 25 to 30 years.", prefix: "先前的译文")
                    && plan("His sister was older.", "by fifteen years.") != nil
                    && plan("The weather was warm.", "by 25 to 30 years.") == nil
                    && plan("The weather was warm", "by 25 to 30 years.") == nil,
                    "continuation_asr_period_after_quantity_predicate_but_not_unrelated_complete_sentence")
        try require(plan("We collected our first", "donation on Monday.") == .completeObject("donation collected on Monday.")
                    && plan("They sent the", "package on Tuesday.") == .completeObject("package sent on Tuesday.")
                    && plan("We did not receive the", "refund until Friday.") == .completeObject("refund was not received until Friday."),
                    "continuation_open_object_preserves_direction_time_and_negation")
        try require(plan("They would send a", "gift tomorrow.") == nil
                    && plan("They made a", "mistake yesterday.") == nil
                    && plan("Please send a", "donation on Friday.") == nil
                    && plan("Do not send a", "donation on Friday.") == nil
                    && plan("Did she receive a", "gift on Monday?") == nil,
                    "continuation_does_not_assert_hypothetical_question_or_idiom")
        try require(plan("The traffic is heavy.", "by six years.") == nil
                    && plan("She received the", "Thanks.") == nil
                    && plan("She received the", "We paid their bill.") == nil
                    && plan("My sister is older", "by six years.", displayed: nil) == nil
                    && plan("The train was delayed", "by one hour.", source: "ja") == nil
                    && plan("The train was delayed", "by one hour.", target: "ja") == nil
                    && plan("The train was delayed", "by one hour.", stable: true) == nil,
                    "continuation_excludes_nonadjacent_reactions_independent_lines_other_directions_and_drafts")
        try require(EnglishSubtitleContinuation.accepted("今天的这个说法。", prefix: "今天的这个说法", original: "for six days.") == nil
                    && EnglishSubtitleContinuation.accepted("。", prefix: "可以持续", original: "for six days.") == nil
                    && EnglishSubtitleContinuation.accepted("六天。", prefix: "可以持续", original: "for six days.") == "六天。",
                    "continuation_never_emits_supplied_prefix_or_empty_suffix")
        let lag = EnglishLagMeasurement.read("Back behind by 25 to 30 years")
        try require(lag?.standalone == true && lag?.chinese == "落后25到30年"
                    && EnglishLagMeasurement.read("Lagged behind by roughly twenty-five to thirty months.")?.chinese == "落后约25到30个月"
                    && EnglishLagMeasurement.read("Behind by 4–6 weeks.")?.chinese == "落后4到6周"
                    && EnglishLagMeasurement.read("Fell behind by a year.")?.chinese == "落后1年",
                    "lag_comparison_preserves_direction_range_qualifier_and_units")
        let modal = EnglishLagMeasurement.read("We might not fall behind by four years.")
        try require(modal?.standalone == false && modal?.chinese == "落后4年"
                    && EnglishLagMeasurement.read("Are we behind by two months?")?.standalone == false
                    && EnglishLagMeasurement.read("She was 25 to 30 years old.") == nil
                    && EnglishLagMeasurement.read("Go back by 25 years.") == nil
                    && EnglishLagMeasurement.read("We left it behind 25 years ago.") == nil
                    && EnglishLagMeasurement.read("They were ahead by four years.") == nil
                    && EnglishLagMeasurement.read("The bridge is behind the museum.") == nil,
                    "lag_comparison_preserves_negation_questions_and_excludes_age_history_lead_and_space")
        try require(plan("Styles in the west", "by 25 to 30 years.", displayed: "西方风格") == nil
                    && EnglishLagMeasurement.neutralYears("by 25 to 30 years.") == "25到30年"
                    && EnglishLagMeasurement.neutralYears("By about six years!") == "约6年"
                    && EnglishLagMeasurement.neutralYears("by the age of 30") == nil
                    && EnglishLagMeasurement.neutralYears("by 25 years ago") == nil
                    && EnglishLagMeasurement.neutralYears("By two years, we mean the entire period.") == nil
                    && EnglishLagMeasurement.ageIsExplicit(in: "His brother was younger")
                    && !EnglishLagMeasurement.ageIsExplicit(in: "Styles in the west"),
                    "orphan_years_preserve_duration_without_guessing_age_direction_or_reference_time")
        try require(EnglishLagMeasurement.repairAgeUnit(in: "約25至30歲。", original: "by about 25 to 30 years", preceding: "Styles in the west") == "约25到30年。"
                    && EnglishLagMeasurement.repairAgeUnit(in: "25至30歲。", original: "by 25 to 30 years", preceding: "His sister was older") == "25至30歲。"
                    && EnglishLagMeasurement.repairAgeUnit(in: "25至30歲，第3組。", original: "by 25 to 30 years", preceding: nil) == "25至30歲，第3組。"
                    && EnglishLagMeasurement.repairAgeUnit(in: "25岁。", original: "by the age of 25", preceding: nil) == "25岁。"
                    && EnglishLagMeasurement.repairAgeUnit(in: "落后25年。", original: "by 25 years", preceding: nil) == "落后25年。",
                    "orphan_years_cloud_repair_only_for_a_pure_age_answer_without_age_evidence")
        return checks
    }
}
