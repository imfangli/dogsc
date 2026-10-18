import Foundation
import RecorderCore

/// Request capacities should not force a subtitle boundary in the middle of a
/// word. Keep complete ASR units, but prefer a nearby linguistic boundary when
/// another request is needed for the same editable run.
enum SubtitleAIBatching {
    static func ranges(
        words: [SubtitleWord], protectedWordIDs: Set<UUID>,
        unitLimit: Int, characterLimit: Int
    ) -> [Range<Int>] {
        let unitLimit = max(unitLimit, 1)
        let characterLimit = max(characterLimit, 1)
        var ranges: [Range<Int>] = []
        var start = 0
        while start < words.count {
            if protectedWordIDs.contains(words[start].id) {
                start += 1
                continue
            }
            var hardEnd = start
            var characters = 0
            while hardEnd < words.count, hardEnd - start < unitLimit,
                  !protectedWordIDs.contains(words[hardEnd].id) {
                let count = words[hardEnd].text.count
                // A single oversized unit remains intact; its timestamp has
                // no reliable internal boundary at which to split it.
                if hardEnd > start && characters + count > characterLimit { break }
                characters += count
                hardEnd += 1
            }
            let needsAnotherBatch = hardEnd < words.count
                && !protectedWordIDs.contains(words[hardEnd].id)
            let end = needsAnotherBatch
                ? preferredEnd(words: words, start: start, hardEnd: hardEnd)
                : hardEnd
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// Accept closing quotation marks and surrounding whitespace, but do not
    /// mistake dotted English acronyms/initials or abbreviations for sentences.
    static func isSentenceBoundary(_ text: String) -> Bool {
        let ending = withoutClosingPunctuation(text)
        guard let last = ending.last else { return false }
        if sentencePunctuation.contains(last) { return true }
        guard last == "." else { return false }
        var tokenStart = ending.endIndex
        while tokenStart > ending.startIndex {
            let previous = ending.index(before: tokenStart)
            let character = ending[previous]
            if character != "." && !character.unicodeScalars.allSatisfy(isASCIILetter) { break }
            tokenStart = previous
        }
        let token = ending[tokenStart...]
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        if components.count >= 2, components.last?.isEmpty == true,
           components.dropLast().allSatisfy({ component in
               component.count == 1 && component.unicodeScalars.allSatisfy(isASCIILetter)
           }) {
            return false
        }
        return !englishAbbreviations.contains(token.lowercased())
    }

    private static func preferredEnd(words: [SubtitleWord], start: Int, hardEnd: Int) -> Int {
        // Search only the latter half, so a natural break near the beginning
        // cannot turn a long transcript into many tiny requests.
        let firstCandidate = start + max((hardEnd - start) / 2, 1)
        var sentenceEnd: Int?
        var pauseEnd: Int?
        var clauseEnd: Int?
        var text = ""
        for index in start..<hardEnd {
            text += words[index].text
            let boundary = index + 1
            guard boundary >= firstCandidate else { continue }
            if isSentenceBoundary(text) { sentenceEnd = boundary }
            if hasPlausiblePause(words[index], words[boundary]) { pauseEnd = boundary }
            if withoutClosingPunctuation(text).last.map(clausePunctuation.contains) == true {
                clauseEnd = boundary
            }
        }
        return sentenceEnd ?? pauseEnd ?? clauseEnd ?? hardEnd
    }

    private static func hasPlausiblePause(_ before: SubtitleWord, _ after: SubtitleWord) -> Bool {
        // Multiple source ranges mean a word crossed a cut. Large jumps may
        // also be removed source audio rather than a spoken pause; source
        // anchors alone cannot distinguish those reliably.
        guard before.sourceRanges.count == 1, after.sourceRanges.count == 1,
              let beforeRange = before.sourceRanges.first, beforeRange.isValid,
              let afterRange = after.sourceRanges.first, afterRange.isValid else { return false }
        let gap = afterRange.start - beforeRange.end
        return gap >= 0.5 && gap <= 2
    }

    private static func withoutClosingPunctuation(_ text: String) -> Substring {
        var ending = text[...]
        while let last = ending.last, last.isWhitespace || closingPunctuation.contains(last) {
            ending.removeLast()
        }
        return ending
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static let sentencePunctuation = Set<Character>("。！？!?…")
    private static let clausePunctuation = Set<Character>("，,；;：:")
    private static let closingPunctuation = Set<Character>("\"'”’」』）》】〕〗〙〛»›)]}")
    private static let englishAbbreviations: Set<String> = [
        "dr.", "mr.", "mrs.", "ms.", "prof.", "sr.", "jr.", "vs.", "etc."
    ]
}
