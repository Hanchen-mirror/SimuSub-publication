import Foundation

enum EnglishTranslationChunks {
    static let wordLimit = 48
    static let characterLimit = 420

    /// Normal live sentences stay intact. For a run-on transcript favor a sentence
    /// end, then a comma or semicolon, then a word boundary. Keep every word.
    static func split(_ source: String) throws -> [String] {
        let words = source.split(whereSeparator: \.isWhitespace)
        guard words.count > wordLimit || source.count > characterLimit else { return [source] }
        var result: [String] = []
        var start = 0
        while start < words.count {
            var end = start, length = 0
            var sentenceEnd: Int?, clauseEnd: Int?
            while end < words.count && end - start < wordLimit {
                let size = words[end].count + (end == start ? 0 : 1)
                guard length + size <= characterLimit else { break }
                length += size
                let last = words[end].trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]")).last
                end += 1
                if let last, ".!?".contains(last) { sentenceEnd = end }
                else if let last, ",;:".contains(last) { clauseEnd = end }
            }
            guard end > start else { throw LocalLlamaError.promptTooLong }
            if end < words.count {
                let minimum = start + max(6, (end - start) / 3)
                end = [sentenceEnd, clauseEnd].compactMap { $0 }.first { $0 >= minimum } ?? end
            }
            result.append(words[start..<end].joined(separator: " "))
            start = end
        }
        return result
    }
}
