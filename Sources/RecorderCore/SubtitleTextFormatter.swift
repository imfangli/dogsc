import Foundation

public enum SubtitleTextFormatter {
    /// Presentation rules are local and deterministic, independent of the AI
    /// provider. Graphemes, internal punctuation, decimal points and acronyms
    /// are retained; sentence-ending punctuation is removed.
    public static func format(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { formatLine(String($0)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return removingTerminalPunctuation(lines)
    }

    public static func joinUnits(_ texts: [String]) -> String {
        var result = ""
        for text in texts {
            let unit = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !unit.isEmpty else { continue }
            if let last = result.last, let first = unit.first,
               isLatin(last) && isLatin(first) {
                result.append(" ")
            }
            result.append(unit)
        }
        return format(result)
    }

    private static func formatLine(_ source: String) -> String {
        let line = source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let characters = Array(line)
        var result = ""
        var index = 0
        while index < characters.count {
            if isTermCharacter(characters[index]) {
                let start = index
                while index < characters.count, isTermCharacter(characters[index]) { index += 1 }
                let token = characters[start..<index]
                let containsLatin = token.contains(where: isLatin)
                if containsLatin, let previous = result.last, isHan(previous) { result.append(" ") }
                result.append(contentsOf: token)
                if containsLatin, index < characters.count, isHan(characters[index]) { result.append(" ") }
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    private static func isTermCharacter(_ character: Character) -> Bool {
        if isLatin(character) || "-._+/".contains(character) { return true }
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x30...0x39).contains(scalar.value) || (0xFF10...0xFF19).contains(scalar.value)
    }

    private static func removingTerminalPunctuation(_ source: String) -> String {
        var line = source
        let terminal: Set<Character> = Set("。！？.!?,，;；:：…")
        while let last = line.last, terminal.contains(last) {
            // The final dot is part of U.S. / A.I., rather than a sentence stop.
            if last == ".", line.range(of: "(?:[A-Za-z]\\.){2,}$", options: .regularExpression) != nil {
                break
            }
            line.removeLast()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private static func isLatin(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF,
             0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return scalar.properties.isAlphabetic
        default: return false
        }
    }

    private static func isHan(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF:
            return true
        default: return false
        }
    }
}

/// Sensible initial sentence groups, bounded by timed units rather than made-up
/// character timestamps. An unusually long smallest ASR unit remains intact.
public enum SubtitleSegmentation {
    public static func cues(for words: [SubtitleWord]) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        var pending: [SubtitleWord] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let text = SubtitleTextFormatter.joinUnits(pending.map(\.text))
            if !text.isEmpty { result.append(SubtitleCue(wordIDs: pending.map(\.id), text: text)) }
            pending.removeAll(keepingCapacity: true)
        }
        for word in words {
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !word.sourceRanges.isEmpty else { continue }
            let gap = (word.sourceRanges.first?.start ?? 0) - (pending.last?.sourceRanges.last?.end ?? 0)
            let duration = pending.reduce(0.0) { $0 + $1.sourceRanges.reduce(0.0) { $0 + $1.duration } }
            let length = pending.reduce(0) { $0 + $1.text.count }
            if !pending.isEmpty && (gap > 0.65 || gap < -0.001 || duration > 4.5 || length + word.text.count > 32) {
                flush()
            }
            pending.append(word)
            if let last = word.text.trimmingCharacters(in: .whitespacesAndNewlines).last,
               "。！？!?；;".contains(last) { flush() }
        }
        flush()
        return result
    }
}
