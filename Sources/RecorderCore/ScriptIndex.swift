import Foundation

/// An immutable search index whose ranges always refer to the unmodified memo.
public struct ScriptIndex: Sendable {
    public let text: String
    let units: [ScriptUnit]
    let identifiers: [Int]
    let vocabulary: [String: Int]
    let trigrams: [ScriptTrigram: [Int]]
    private let sentences: [NSRange]

    /// Uses the same units as matching so a coalescer can retain the first
    /// meaningful partial without treating punctuation or spaces as evidence.
    public static func effectiveUnitCount(in text: String) -> Int {
        ScriptNormalizer.units(in: text).count
    }

    public init(text: String) {
        self.text = text
        units = ScriptNormalizer.units(in: text)
        var vocabulary: [String: Int] = [:]
        var identifiers: [Int] = []
        identifiers.reserveCapacity(units.count)
        for unit in units {
            let identifier = vocabulary[unit.value] ?? vocabulary.count + 1
            vocabulary[unit.value] = identifier
            identifiers.append(identifier)
        }
        self.vocabulary = vocabulary
        self.identifiers = identifiers
        var trigrams: [ScriptTrigram: [Int]] = [:]
        if identifiers.count >= 3 {
            for position in 0..<(identifiers.count - 2) {
                let key = ScriptTrigram(identifiers, at: position)
                trigrams[key, default: []].append(position)
            }
        }
        self.trigrams = trigrams
        sentences = Self.sentenceRanges(in: text)
    }

    public func sentenceRange(atUTF16Offset offset: Int) -> NSRange? {
        guard !sentences.isEmpty else { return nil }
        let offset = max(0, min(offset, max(0, text.utf16.count - 1)))
        var lower = 0
        var upper = sentences.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(sentences[middle]) <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        return sentences[min(lower, sentences.count - 1)]
    }

    func unitPosition(atUTF16Offset offset: Int) -> Int? {
        guard !units.isEmpty else { return nil }
        var lower = 0
        var upper = units.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(units[middle].range) <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        return min(lower, units.count - 1)
    }

    func originalRange(from start: Int, to end: Int) -> NSRange? {
        guard start >= 0, end > start, end <= units.count else { return nil }
        let first = units[start].range
        let last = units[end - 1].range
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    private static func sentenceRanges(in text: String) -> [NSRange] {
        let elements = ScriptNormalizer.elements(in: text)
        guard !elements.isEmpty else { return [] }
        var result: [NSRange] = []
        var start = 0
        func append(through end: Int) {
            var first = start
            var last = end
            while first <= last, elements[first].isWhitespace { first += 1 }
            while last >= first, elements[last].isWhitespace { last -= 1 }
            if first <= last {
                let lower = elements[first].range.location
                result.append(NSRange(location: lower, length: NSMaxRange(elements[last].range) - lower))
            }
            start = end + 1
        }
        for position in elements.indices {
            let value = elements[position].value
            let decimalPoint = value == "." && position > 0 && position + 1 < elements.count
                && ScriptNormalizer.isDigit(elements[position - 1].value)
                && ScriptNormalizer.isDigit(elements[position + 1].value)
            let isNewline = value.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
            if isNewline || "。！？!?；;".contains(value) || (value == "." && !decimalPoint) {
                append(through: position)
            }
        }
        if start < elements.count { append(through: elements.count - 1) }
        return result
    }
}

struct ScriptTrigram: Hashable, Sendable {
    let first: Int
    let second: Int
    let third: Int
    init(_ identifiers: [Int], at position: Int) {
        first = identifiers[position]
        second = identifiers[position + 1]
        third = identifiers[position + 2]
    }
}

struct ScriptUnit: Sendable {
    let value: String
    let range: NSRange
}

enum ScriptNormalizer {
    struct Element {
        let value: String
        let range: NSRange
        var isWhitespace: Bool {
            value.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
    }

    static func elements(in text: String) -> [Element] {
        var offset = 0
        return text.map { character in
            let original = String(character)
            let length = original.utf16.count
            defer { offset += length }
            return Element(value: original.folding(options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")), range: NSRange(location: offset, length: length))
        }
    }

    static func units(in text: String) -> [ScriptUnit] {
        let elements = elements(in: text)
        var result: [ScriptUnit] = []
        result.reserveCapacity(elements.count)
        var position = 0
        while position < elements.count {
            let start = position
            var numberStart = position
            let negative = elements[numberStart].value == "-" || elements[numberStart].value == "负"
            if negative { numberStart += 1 }
            var percentPrefix = false
            if numberStart + 3 < elements.count,
               elements[numberStart].value == "百", elements[numberStart + 1].value == "分",
               elements[numberStart + 2].value == "之" {
                numberStart += 3
                while numberStart < elements.count, elements[numberStart].isWhitespace { numberStart += 1 }
                percentPrefix = true
            }
            if numberStart < elements.count, isNumberCharacter(elements[numberStart].value) {
                var end = numberStart
                var number = ""
                while end < elements.count {
                    let value = elements[end].value
                    if isNumberCharacter(value) { number += value; end += 1 }
                    else if value == ",", end > numberStart, isGroupingComma(elements, at: end) { end += 1 }
                    else if (value == "." || value == "点"), end > numberStart,
                            end + 1 < elements.count, isDigit(elements[end + 1].value) {
                        number += "."; end += 1
                    } else { break }
                }
                var percent = percentPrefix
                if end < elements.count, elements[end].value == "%" { percent = true; end += 1 }
                if let canonical = canonicalNumber(number) {
                    let lower = elements[start].range.location
                    let range = NSRange(location: lower, length: NSMaxRange(elements[end - 1].range) - lower)
                    result.append(ScriptUnit(value: "#" + (negative && canonical != "0" ? "-" : "")
                        + canonical + (percent ? "%" : ""), range: range))
                    position = end
                    continue
                }
            }
            let element = elements[position]
            // One normalized unit may expand into several letters. All retain
            // the same original grapheme range, including decomposed accents.
            for character in element.value {
                let value = String(character)
                if value.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) {
                    result.append(ScriptUnit(value: value, range: element.range))
                }
            }
            position += 1
        }
        return result
    }

    private static let chineseDigits: [String: Int64] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let smallUnits: [String: Int64] = ["十": 10, "百": 100, "千": 1_000]
    private static let largeUnits: [String: Int64] = ["万": 10_000, "亿": 100_000_000]

    static func isDigit(_ value: String) -> Bool {
        chineseDigits[value] != nil || (value.utf8.count == 1 && value.utf8.first.map { (48...57).contains($0) } == true)
    }
    private static func isNumberCharacter(_ value: String) -> Bool {
        isDigit(value) || smallUnits[value] != nil || largeUnits[value] != nil
    }
    private static func isGroupingComma(_ elements: [Element], at position: Int) -> Bool {
        guard position + 3 < elements.count else { return false }
        func isASCIIDigit(_ value: String) -> Bool {
            value.utf8.count == 1 && value.utf8.first.map { (48...57).contains($0) } == true
        }
        guard (1...3).allSatisfy({ isASCIIDigit(elements[position + $0].value) }) else { return false }
        return position + 4 >= elements.count || !isASCIIDigit(elements[position + 4].value)
    }
    private static func digitValue(_ value: String) -> Int64? {
        chineseDigits[value] ?? Int64(value)
    }

    private static func canonicalNumber(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let integer = canonicalInteger(String(parts[0])) else { return nil }
        guard parts.count == 2 else { return integer }
        var fraction = ""
        for character in parts[1] {
            guard let digit = digitValue(String(character)), digit < 10 else { return nil }
            fraction += String(digit)
        }
        guard !fraction.isEmpty else { return nil }
        while fraction.last == "0" { fraction.removeLast() }
        return fraction.isEmpty ? integer : integer + "." + fraction
    }

    private static func canonicalInteger(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let values = text.map(String.init)
        if values.allSatisfy({ isDigit($0) }) {
            var digits = values.compactMap { digitValue($0).map(String.init) }.joined()
            while digits.count > 1, digits.first == "0" { digits.removeFirst() }
            return digits
        }
        // Deliberately limited to ordinary descending Chinese units. Unusual
        // expressions such as “一万亿” remain literal instead of guessing.
        var total: Int64 = 0
        var section: Int64 = 0
        var number: Int64 = 0
        var previousLargeUnit = Int64.max
        for value in values {
            if let digit = digitValue(value) {
                guard number < 1_000_000_000 else { return nil }
                number = number * 10 + digit
            } else if let unit = smallUnits[value] {
                section += max(1, number) * unit
                number = 0
            } else if let unit = largeUnits[value] {
                guard unit < previousLargeUnit else { return nil }
                let subtotal = section + number
                guard subtotal < 1_000_000_000 else { return nil }
                total += max(1, subtotal) * unit
                section = 0
                number = 0
                previousLargeUnit = unit
            } else { return nil }
        }
        return String(total + section + number)
    }
}
