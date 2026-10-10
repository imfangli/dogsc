import AppKit

/// Compress whitespace-only paragraphs in TextKit's layout without changing
/// the manuscript, character indexes, attributed text, or native copy/undo.
@MainActor
final class MemoBlankLineLayoutDelegate: NSObject, @preconcurrency NSLayoutManagerDelegate {
    private var source: String?
    private var isEnabled = false
    private var hiddenCharacters = IndexSet()

    @discardableResult
    func update(text: String, isEnabled: Bool, layoutManager: NSLayoutManager) -> Bool {
        guard source != text || self.isEnabled != isEnabled else { return false }
        let wasEnabled = self.isEnabled
        source = text
        self.isEnabled = isEnabled
        // Keep the original editor/reader path untouched until folding is
        // actually enabled. Premature re-layout can observe a transient width.
        guard wasEnabled || isEnabled else { return false }
        hiddenCharacters = isEnabled ? blankParagraphCharacters(in: text as NSString) : IndexSet()
        layoutManager.delegate = isEnabled ? self : nil
        let all = NSRange(location: 0, length: (text as NSString).length)
        // Layout-only invalidation can retain the old usedRect after native
        // editing. Regenerate glyph geometry to refresh document bounds too.
        layoutManager.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: all)
        return true
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0, isHiddenGlyph(glyphRange.location, in: layoutManager) else { return false }
        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.origin.y = lineFragmentRect.pointee.origin.y
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
    }

    private func isHiddenGlyph(_ glyphIndex: Int, in layout: NSLayoutManager) -> Bool {
        hiddenCharacters.contains(layout.characterIndexForGlyph(at: glyphIndex))
    }

    private func blankParagraphCharacters(in string: NSString) -> IndexSet {
        var hidden = IndexSet()
        var offset = 0
        while offset < string.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            guard end > offset else { break }
            let contents = NSRange(location: start, length: contentsEnd - start)
            let nonWhitespace = string.rangeOfCharacter(from: CharacterSet.whitespaces.inverted, options: [], range: contents)
            if nonWhitespace.location == NSNotFound { hidden.insert(integersIn: start..<end) }
            offset = end
        }
        return hidden
    }
}
