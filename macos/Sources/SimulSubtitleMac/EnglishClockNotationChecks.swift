import Foundation

enum EnglishClockNotationChecks {
    static func run() throws -> [String] {
        var passed: [String] = []
        func check(_ name: String, _ actual: String, _ expected: String) throws {
            guard actual == expected else {
                throw NSError(domain: "EnglishClockNotationChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "\(name): expected «\(expected)», got «\(actual)»"])
            }
            passed.append("english_clock_" + name)
        }

        let examples: [(String, String, String)] = [
            ("noisy_clock_asr_with_zone", "Protestatred around 1100 local time UTC+1", "Protestatred around 11:00 local time UTC+1"),
            ("clock_reading", "The clock reads 640.", "The clock reads 6:40."),
            ("explicit_current_time", "The local time is 640.", "The local time is 6:40."),
            ("ambiguous_price_or_time", "It is 640.", "It is 640."),
            ("non_clock_reading", "The meter reads 640.", "The meter reads 640."),
            ("transport", "The last bus leaves at 640, so finish packing all the equipment by 620.",
             "The last bus leaves at 6:40, so finish packing all the equipment by 6:20."),
            ("fronted", "At 215 the engineer sent a new schedule.", "At 2:15 the engineer sent a new schedule."),
            ("decimal", "The meeting starts at 10.30.", "The meeting starts at 10:30."),
            ("human_local_time", "The protest started around 1100 local time UTC.", "The protest started around 11:00 local time UTC."),
            ("offset", "The event starts at 2130 UTC+1.", "The event starts at 21:30 UTC+1."),
            ("gmt", "Doors open at 0905 GMT.", "Doors open at 09:05 GMT."),
            ("street_with_timezone_name", "We meet at 1100 UTC Avenue.", "We meet at 1100 UTC Avenue."),
            ("street_before_timezone", "We meet at 1100 Park Avenue, local time unknown.", "We meet at 1100 Park Avenue, local time unknown."),
            ("archive_timezone", "The archives begin around 1945, local time unknown.", "The archives begin around 1945, local time unknown."),
            ("evening", "The reading starts at 805 this evening.", "The reading starts at 8:05 this evening."),
            ("delivery", "Deliver them by 1645 tomorrow.", "Deliver them by 16:45 tomorrow."),
            ("leading_zero", "Doors open at 0905.", "Doors open at 09:05."),
            ("colon", "The alarm is set for 08:05.", "The alarm is set for 08:05."),
            ("order_and_time", "Order 640 includes 620 labels. Deliver them by 640 tomorrow.",
             "Order 640 includes 620 labels. Deliver them by 6:40 tomorrow."),
            ("duration", "The staff worked for 640 hours.", "The staff worked for 640 hours."),
            ("quantity_tomorrow", "We deliver 640 tomorrow.", "We deliver 640 tomorrow."),
            ("price_tomorrow", "Prices start at 640 tomorrow.", "Prices start at 640 tomorrow."),
            ("historical_year", "The archives begin at 1750.", "The archives begin at 1750."),
            ("archive_year", "The archives end at 1945.", "The archives end at 1945."),
            ("price", "The camera is priced at 10.30 dollars.", "The camera is priced at 10.30 dollars."),
            ("bid", "Bidding starts at 640.", "Bidding starts at 640."),
            ("quantity", "The head count increased by 620.", "The head count increased by 620."),
            ("units", "We finish at 640 units per day.", "We finish at 640 units per day."),
            ("address", "We meet at 640 Main Street.", "We meet at 640 Main Street."),
            ("model", "Look at 640 or order model AX-620.", "Look at 640 or order model AX-620."),
            ("order", "Look at order 215 and invoice 10.30.", "Look at order 215 and invoice 10.30."),
            ("invalid", "We leave at 2561, then arrive at 987.", "We leave at 2561, then arrive at 987."),
            ("date", "The meeting starts at 10.30.2026 on the spreadsheet.", "The meeting starts at 10.30.2026 on the spreadsheet."),
            ("championship", "The final score was 6:40.", "The final score was 6:40.")
        ]
        for (name, input, expected) in examples {
            try check(name, EnglishClockNotation.source(input), expected)
            try check(name + "_idempotent", EnglishClockNotation.source(expected), expected)
        }
        try check("cross_cue", EnglishClockNotation.source("640 sharp.", previous: "Our train leaves at"), "6:40 sharp.")
        try check("cross_cue_price", EnglishClockNotation.source("640.", previous: "Bidding starts at"), "640.")
        try check("cross_cue_address", EnglishClockNotation.source("640 King Street.", previous: "Our group meets at"), "640 King Street.")
        try check("cross_cue_unrelated", EnglishClockNotation.source("640.", previous: "The train left yesterday."), "640.")
        let timetable = "See what time the tidal train starts tomorrow morning."
        let replies = [
            ("librivox", "at 640 Mr Franklin.", timetable, "at 6:40 Mr Franklin."),
            ("librivox_comma", "at 640, Mr. Franklin.", timetable, "at 6:40, Mr. Franklin."),
            ("librivox_merged", timetable + " At 640, sir.", "", timetable + " At 6:40, sir."),
            ("librivox_unpunctuated", "See what time the train leaves at 640, sir.", "", "See what time the train leaves at 6:40, sir."),
            ("ferry", "805, ma’am.", "When does the ferry depart?", "8:05, ma’am."),
            ("short", "805.", "What time is breakfast?", "8:05."),
            ("numbered_street", "At 640 Baker Street, sir.", timetable, "At 640 Baker Street, sir."),
            ("currency", "At 640 dollars, sir.", timetable, "At 640 dollars, sir."),
            ("currency_question", "At 640, sir.", "What is the price?", "At 640, sir."),
            ("quantity_question", "640, Mr Jones.", "How many tickets?", "640, Mr Jones."),
            ("order_question", "At 640, sir.", "What time did they open? Which order was yours?", "At 640, sir."),
            ("time_zone_question", "640, sir.", "What time zone?", "640, sir."),
            ("year", "1945, sir.", timetable, "1945, sir."),
            ("name_alone", "At 640, Mr Franklin.", "", "At 640, Mr Franklin.")
        ]
        for (name, input, previous, expected) in replies {
            try check(name, EnglishClockNotation.source(input, previous: previous), expected)
        }
        let bilingual: [(String, String, String, String)] = [
            ("reply_hans", "at 6:40 Mr Franklin.", "640号，弗兰克林先生。", "6:40，弗兰克林先生。"),
            ("reply_hant", "at 6:40, Mr. Franklin.", "640號，富蘭克林先生。", "6:40，富蘭克林先生。"),
            ("reply_bare", "6:40, sir.", "640。", "6:40。"),
            ("reply_order", "at 6:40, sir.", "订单640号。", "订单640号。"),
            ("reply_price", "at 6:40, sir.", "640元，先生。", "640元，先生。"),
            ("hans", "The last bus leaves at 6:40. Finish by 6:20.", "最后一班巴士在640出发，请在620前完成。",
             "最后一班巴士在6:40出发，请在6:20前完成。"),
            ("hant", "The bus leaves at 6:40. Finish by 6:20.", "巴士六點四十分出發，請在六點二十分前完成。",
             "巴士6:40出發，請在6:20前完成。"),
            ("chinese_time", "At 2:15 the engineer arrived.", "两点十五分，工程师到了。", "2:15，工程师到了。"),
            ("dotted_time", "The meeting starts at 10:30.", "会议从10.30开始。", "会议从10:30开始。"),
            ("hant_padded", "The hall opens at 08:05.", "會場八點零五分開放。", "會場08:05開放。"),
            ("fullwidth_clock", "The alarm rang at 2:15.", "鬧鐘在2：15響了。", "鬧鐘在2:15響了。"),
            ("same_order", "Order 640 is due by 6:40.", "请在640之前送达订单640。", "请在6:40之前送达订单640。"),
            ("price_and_time", "The item costs 640 dollars. We close at 6:40.", "售价在640美元左右，店铺在640关门。",
             "售价在640美元左右，店铺在6:40关门。"),
            ("different_number", "The train leaves at 6:40.", "请于650发车。", "请于650发车。"),
            ("no_clock", "The model is 640 and the price is 10.30.", "价格为10.30，型号640。", "价格为10.30，型号640。")
        ]
        for (name, source, original, expected) in bilingual {
            try check(name, EnglishClockNotation.translation(original, source: source), expected)
            try check(name + "_idempotent", EnglishClockNotation.translation(expected, source: source), expected)
        }
        return passed
    }
}
