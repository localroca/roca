import Foundation

struct AssistantSpeechChunker {
    static let maxCharacters = 420

    static func chunks(from text: String, maxCharacters: Int = Self.maxCharacters) -> [String] {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !normalized.isEmpty else {
            return []
        }

        var chunks: [String] = []
        var current = ""
        for sentence in sentenceLikeUnits(in: normalized) {
            if sentence.count > maxCharacters {
                appendCurrent(&current, to: &chunks)
                chunks.append(contentsOf: splitLongUnit(sentence, maxCharacters: maxCharacters))
                continue
            }

            let candidate = current.isEmpty ? sentence : "\(current) \(sentence)"
            if candidate.count <= maxCharacters {
                current = candidate
            } else {
                appendCurrent(&current, to: &chunks)
                current = sentence
            }
        }
        appendCurrent(&current, to: &chunks)
        return chunks
    }

    private static func sentenceLikeUnits(in text: String) -> [String] {
        var units: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            current.append(character)
            if isSentenceBoundary(character, in: text, at: index) {
                appendCurrent(&current, to: &units)
            }
            index = text.index(after: index)
        }
        appendCurrent(&current, to: &units)
        return units
    }

    private static func isSentenceBoundary(_ character: Character, in text: String, at index: String.Index) -> Bool {
        guard ".!?".contains(character) else {
            return false
        }
        guard character == "." else {
            return true
        }

        let nextIndex = text.index(after: index)
        if index > text.startIndex, nextIndex < text.endIndex {
            let previous = text[text.index(before: index)]
            let next = text[nextIndex]
            if previous.isNumber && next.isNumber {
                return false
            }
        }
        return nextIndex == text.endIndex || text[nextIndex].isWhitespace
    }

    private static func splitLongUnit(_ text: String, maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let word = String(word)
            if word.count > maxCharacters {
                appendCurrent(&current, to: &chunks)
                chunks.append(contentsOf: splitOverlongWord(word, maxCharacters: maxCharacters))
                continue
            }

            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count <= maxCharacters {
                current = candidate
            } else {
                appendCurrent(&current, to: &chunks)
                current = word
            }
        }
        appendCurrent(&current, to: &chunks)
        return chunks
    }

    private static func splitOverlongWord(_ word: String, maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in word {
            current.append(character)
            if current.count >= maxCharacters {
                chunks.append(current)
                current = ""
            }
        }
        appendCurrent(&current, to: &chunks)
        return chunks
    }

    private static func appendCurrent(_ current: inout String, to values: inout [String]) {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            values.append(trimmed)
        }
        current = ""
    }
}
