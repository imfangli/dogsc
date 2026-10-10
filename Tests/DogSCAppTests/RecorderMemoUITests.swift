import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import DogSCApp

/// Exercise AppKit text layout and scrolling without opening an OS window or
/// requesting microphone access. Speech matching itself is tested separately.
@MainActor
final class RecorderMemoUITests: XCTestCase {
    func testUserSelectionIsReportedWithoutChangingTheManuscript() {
        let manuscript = "先选择这一段，再从选中位置开始跟读。"
        let fixture = makeFixture(manuscript)
        var reportedSelection = NSRange(location: 0, length: 0)
        fixture.coordinator.selectedRange = Binding(get: { reportedSelection }, set: { reportedSelection = $0 })
        let selection = (manuscript as NSString).range(of: "这一段")
        fixture.view.setSelectedRange(selection)
        XCTAssertEqual(reportedSelection, selection,
            "Selections outside SwiftUI's programmatic update should reach the speech controller.")
        XCTAssertEqual(fixture.view.string, manuscript)
    }

    func testTemporaryHighlightPreservesTextSelectionAndUndo() throws {
        let original = "第一句，正式开始。第二句继续说明。"
        let fixture = makeFixture(original)
        let undo = fixture.view.testUndoManager
        undo.beginUndoGrouping()
        fixture.view.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo, "Native text editing should register an undo operation.")

        let edited = fixture.view.string
        let selection = NSRange(location: 3, length: 4)
        fixture.view.setSelectedRange(selection)
        let sentence = (edited as NSString).range(of: "第一句，正式开始。")
        fixture.coordinator.updateHighlight(sentence, in: fixture.view)

        XCTAssertEqual(fixture.view.string, edited)
        XCTAssertEqual(fixture.view.selectedRange(), selection)
        XCTAssertTrue(undo.canUndo)
        XCTAssertNotNil(fixture.layout.temporaryAttribute(.backgroundColor,
            atCharacterIndex: sentence.location, effectiveRange: nil))
        XCTAssertNil(fixture.view.textStorage?.attribute(.backgroundColor,
            at: sentence.location, effectiveRange: nil), "Highlighting must stay out of the text storage.")

        fixture.coordinator.updateHighlight(nil, in: fixture.view)
        XCTAssertNil(fixture.layout.temporaryAttribute(.backgroundColor,
            atCharacterIndex: sentence.location, effectiveRange: nil))
        XCTAssertEqual(fixture.view.selectedRange(), selection)
        undo.undo()
        XCTAssertEqual(fixture.view.string, original, "Following speech must not add or replace an undo operation.")
    }

    func testPartialUTF16RangesHighlightWholeComposedCharacters() throws {
        let text = "开始👩🏽‍💻然后e\u{301}结束"
        let fixture = makeFixture(text)
        let source = text as NSString
        let emoji = source.range(of: "👩🏽‍💻")
        let accent = source.range(of: "e\u{301}")
        let selection = NSRange(location: 0, length: 2)
        fixture.view.setSelectedRange(selection)

        for whole in [emoji, accent] {
            fixture.coordinator.updateHighlight(NSRange(location: whole.location + 1, length: 1), in: fixture.view)
            var effective = NSRange(location: NSNotFound, length: 0)
            let color = fixture.layout.temporaryAttribute(.backgroundColor,
                atCharacterIndex: whole.location, effectiveRange: &effective)
            XCTAssertNotNil(color)
            XCTAssertEqual(effective, whole)
            XCTAssertEqual(fixture.view.string, text)
            XCTAssertEqual(fixture.view.selectedRange(), selection)
        }
        XCTAssertNil(fixture.layout.temporaryAttribute(.backgroundColor,
            atCharacterIndex: emoji.location, effectiveRange: nil), "Moving the highlight should remove the previous one.")
    }

    func testUnpunctuatedParagraphScrollsToMatchedTailWhileHighlightingWholeSentence() async throws {
        let text = String(repeating: "语音跟读可以从稿件中间开始并且随着朗读继续滚动", count: 40)
        let fixture = makeFixture(text)
        let length = (text as NSString).length
        let sentence = NSRange(location: 0, length: length)
        let matched = NSRange(location: length / 2, length: 32)
        let selection = NSRange(location: 4, length: 2)
        fixture.view.setSelectedRange(selection)
        fixture.coordinator.updateHighlight(sentence, in: fixture.view)
        fixture.coordinator.follow(matched, in: fixture.view, scroll: fixture.scroll)
        defer { fixture.coordinator.cancelScrollAnimation() }
        try await Task.sleep(for: .milliseconds(420))

        let expected = expectedTailScrollOrigin(matched, fixture: fixture)
        XCTAssertGreaterThan(expected, fixture.scroll.contentView.bounds.height,
            "A mid-paragraph match should advance past the sentence's opening lines.")
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, expected, accuracy: 1)
        XCTAssertEqual(fixture.view.string, text)
        XCTAssertEqual(fixture.view.selectedRange(), selection)
        var highlighted = NSRange(location: NSNotFound, length: 0)
        XCTAssertNotNil(fixture.layout.temporaryAttribute(.backgroundColor,
            atCharacterIndex: 0, effectiveRange: &highlighted))
        XCTAssertEqual(highlighted, sentence, "Scroll position and sentence highlighting should remain independent.")
    }

    func testManualWheelCancelsAnimationAndLaterMatchResumesFollowing() async throws {
        let text = String(repeating: "跳读以后应当找到稿件位置并继续跟随朗读", count: 40)
        let fixture = makeFixture(text)
        let length = (text as NSString).length
        let matched = NSRange(location: length / 2, length: 30)
        fixture.coordinator.follow(matched, in: fixture.view, scroll: fixture.scroll)
        defer { fixture.coordinator.cancelScrollAnimation() }
        try await Task.sleep(for: .milliseconds(50))

        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: -30, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        fixture.scroll.scrollWheel(with: event)
        XCTAssertTrue(fixture.scroll.isUserScrolling)
        let manual = NSPoint(x: 0, y: 45)
        fixture.scroll.contentView.scroll(to: manual)
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        let manuallyScrolledY = fixture.scroll.contentView.bounds.origin.y
        fixture.coordinator.follow(matched, in: fixture.view, scroll: fixture.scroll)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, manuallyScrolledY, accuracy: 1,
            "Neither the canceled animation nor a match during a wheel gesture should move the viewport.")
        XCTAssertFalse(fixture.scroll.isUserScrolling)

        // The same sentence may be matched again after manual scrolling.
        // A later reliable revision must resume following without a new range.
        fixture.coordinator.followRevision &+= 1
        fixture.coordinator.follow(matched, in: fixture.view, scroll: fixture.scroll)
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y,
            expectedTailScrollOrigin(matched, fixture: fixture), accuracy: 1)
        XCTAssertGreaterThan(fixture.scroll.contentView.bounds.origin.y, manuallyScrolledY + 100)
    }

    func testHostedMemoCanShrinkAfterPastingLongManuscript() async throws {
        let fixture = try makeHostedFixture()
        defer { fixture.dispose() }
        await settleLayout(fixture.panel)
        let manuscript = String(repeating: "这是需要完整保留的口播文稿，粘贴后只能让内部文档变长，不应限制备忘录窗口的高度。\n", count: 160)
        fixture.store.text = manuscript
        await settleLayout(fixture.panel)
        let hostView = try XCTUnwrap(fixture.panel.contentViewController?.view)
        let scroll = try XCTUnwrap(findMemoScrollView(in: hostView))
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(textView.string, manuscript)
        XCTAssertGreaterThan(textView.frame.height, scroll.contentView.bounds.height * 2)
        XCTAssertLessThanOrEqual(fixture.panel.contentMinSize.height, 340,
            "The hosting controller must not promote document height into the panel's minimum height.")

        shrink(fixture.panel, to: 360)
        await settleLayout(fixture.panel)
        XCTAssertEqual(fixture.panel.frame.height, 360, accuracy: 1)
        XCTAssertEqual(fixture.panel.frame.width, 390, accuracy: 1)
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 70)
        XCTAssertLessThan(scroll.contentView.bounds.height, 300,
            "The scroll viewport should shrink with the window while the manuscript remains scrollable.")
        XCTAssertGreaterThan(textView.frame.height, scroll.contentView.bounds.height * 2)
        XCTAssertEqual(textView.string, manuscript)

        // Reading mode and the largest font must still fit a user-sized panel.
        fixture.store.isEditing = false
        fixture.store.fontSize = 40
        await settleLayout(fixture.panel)
        XCTAssertEqual(fixture.panel.frame.height, 360, accuracy: 1)
        XCTAssertLessThanOrEqual(fixture.panel.contentMinSize.height, 340)
        XCTAssertEqual(fixture.store.text, manuscript)
        XCTAssertEqual(textView.string, manuscript)
    }

    func testHostedShortMemoDocumentDoesNotRetainThePreviousTallViewport() async throws {
        let fixture = try makeHostedFixture()
        defer { fixture.dispose() }
        fixture.store.text = "简短的备忘录"
        await settleLayout(fixture.panel)
        let hostView = try XCTUnwrap(fixture.panel.contentViewController?.view)
        let scroll = try XCTUnwrap(findMemoScrollView(in: hostView))
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        let tallViewport = scroll.contentView.bounds.height
        XCTAssertGreaterThan(tallViewport, 400)

        shrink(fixture.panel, to: 360)
        await settleLayout(fixture.panel)
        XCTAssertEqual(fixture.panel.frame.height, 360, accuracy: 1)
        XCTAssertLessThan(scroll.contentView.bounds.height, tallViewport - 200)
        XCTAssertEqual(textView.minSize.height, scroll.contentView.bounds.height, accuracy: 1)
        XCTAssertEqual(textView.frame.height, scroll.contentView.bounds.height, accuracy: 1,
            "A short document must not keep the height of an earlier larger viewport.")
        XCTAssertEqual(textView.string, "简短的备忘录")
    }

    func testBlankLineFoldingKeepsOriginalCopySelectionAndUndo() throws {
        let original = "开场说明。\n\n \t\u{3000}\r\n第二段内容。\r\n\r\n第三段。"
        let fixture = makeFixture(original)
        let undo = fixture.view.testUndoManager
        undo.beginUndoGrouping()
        fixture.view.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        let source = fixture.view.string
        applyMemoParagraphStyle(to: fixture.view)
        fixture.layout.ensureLayout(for: fixture.container)
        let originalHeight = fixture.layout.usedRect(for: fixture.container).height
        let originalAttributes = try XCTUnwrap(fixture.view.textStorage?.copy() as? NSAttributedString)
        let selection = NSRange(location: 0, length: (source as NSString).length)
        fixture.view.setSelectedRange(selection)

        fixture.coordinator.blankLineLayout.update(text: source, isEnabled: true, layoutManager: fixture.layout)
        fixture.layout.ensureLayout(for: fixture.container)
        XCTAssertLessThan(fixture.layout.usedRect(for: fixture.container).height, originalHeight)
        XCTAssertEqual(fixture.view.string, source)
        XCTAssertEqual(fixture.view.selectedRange(), selection)
        XCTAssertTrue(try XCTUnwrap(fixture.view.textStorage).isEqual(to: originalAttributes))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DogSC.BlankLinesTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(fixture.view.writeSelection(to: pasteboard, types: fixture.view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), source,
            "Native copy must include the source blank lines and CRLF separators.")

        fixture.coordinator.blankLineLayout.update(text: source, isEnabled: false, layoutManager: fixture.layout)
        fixture.layout.ensureLayout(for: fixture.container)
        XCTAssertEqual(fixture.layout.usedRect(for: fixture.container).height, originalHeight, accuracy: 0.5)
        XCTAssertEqual(fixture.view.selectedRange(), selection)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(fixture.view.string, original, "Display folding must leave native undo intact.")
    }

    func testBlankParagraphsCollapseWithoutRemovingOrdinaryLFOrCRLFLineBreaks() {
        for separator in ["\n", "\r\n"] {
            let ordinary = makeFixture("第一段" + separator + "第二段")
            let source = "第一段" + separator + separator + " \t\u{3000}" + separator + "第二段"
            let folded = makeFixture(source)
            for fixture in [ordinary, folded] { applyMemoParagraphStyle(to: fixture.view) }
            folded.coordinator.blankLineLayout.update(text: source, isEnabled: true, layoutManager: folded.layout)
            for fixture in [ordinary, folded] { fixture.layout.ensureLayout(for: fixture.container) }
            let first = lineRect(for: "第一段", fixture: folded)
            let second = lineRect(for: "第二段", fixture: folded)
            XCTAssertGreaterThan(first.height, 0)
            XCTAssertGreaterThan(second.minY, first.minY, "An ordinary newline must remain visible.")
            XCTAssertEqual(second.minY, lineRect(for: "第二段", fixture: ordinary).minY, accuracy: 0.5)
            XCTAssertEqual(folded.layout.usedRect(for: folded.container).height,
                ordinary.layout.usedRect(for: ordinary.container).height, accuracy: 0.5)
            XCTAssertEqual(folded.view.string, source)
        }
    }

    func testLeadingTrailingAndWrappedWhitespaceParagraphsDoNotAccumulateHeight() {
        let body = "保留这一行"
        let ordinary = makeFixture(body + "\n")
        applyMemoParagraphStyle(to: ordinary.view)
        ordinary.layout.ensureLayout(for: ordinary.container)
        let expectedHeight = ordinary.layout.usedRect(for: ordinary.container).height
        let whitespace = String(repeating: " \t\u{3000}", count: 300)
        let source = "\n \t\r\n" + whitespace + "\n" + body + "\r\n\n\r\n" + whitespace + "\n\n"
        let folded = makeFixture(source)
        applyMemoParagraphStyle(to: folded.view)
        folded.coordinator.blankLineLayout.update(text: source, isEnabled: true, layoutManager: folded.layout)
        folded.layout.ensureLayout(for: folded.container)
        XCTAssertEqual(lineRect(for: body, fixture: folded).minY, 0, accuracy: 0.5)
        XCTAssertEqual(folded.layout.usedRect(for: folded.container).height, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(folded.view.string, source)

        let allBlankSource = "\n\r\n \t\u{3000}\r\n" + whitespace + "\n\n"
        let allBlank = makeFixture(allBlankSource)
        applyMemoParagraphStyle(to: allBlank.view)
        allBlank.coordinator.blankLineLayout.update(text: allBlankSource, isEnabled: true, layoutManager: allBlank.layout)
        allBlank.scroll.needsLayout = true
        allBlank.scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(allBlank.layout.usedRect(for: allBlank.container).height,
            allBlank.layout.extraLineFragmentRect.height + 0.5,
            "Only TextKit's normal final caret-line allowance may remain for an all-blank manuscript.")
        XCTAssertEqual(allBlank.view.frame.height, allBlank.scroll.contentView.bounds.height, accuracy: 1)
        XCTAssertEqual(allBlank.view.string, allBlankSource)
    }

    func testFoldedLayoutStillHighlightsAndFollowsOriginalUTF16Ranges() async throws {
        let source = String(repeating: "前面保持普通段落的朗读内容。\n\n \t\u{3000}\r\n", count: 40) + "末段👩🏽‍💻的朗读位置。"
        let fixture = makeFixture(source)
        applyMemoParagraphStyle(to: fixture.view)
        fixture.layout.ensureLayout(for: fixture.container)
        let expandedHeight = fixture.layout.usedRect(for: fixture.container).height
        let sourceRange = (source as NSString).range(of: "末段👩🏽‍💻的朗读位置。")
        fixture.coordinator.updateHighlight(sourceRange, in: fixture.view)
        let selection = NSRange(location: 2, length: 4)
        fixture.view.setSelectedRange(selection)

        fixture.coordinator.blankLineLayout.update(text: source, isEnabled: true, layoutManager: fixture.layout)
        fixture.scroll.needsLayout = true
        fixture.scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThan(fixture.layout.usedRect(for: fixture.container).height, expandedHeight)
        fixture.coordinator.follow(sourceRange, in: fixture.view, scroll: fixture.scroll)
        defer { fixture.coordinator.cancelScrollAnimation() }
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y,
            expectedTailScrollOrigin(sourceRange, fixture: fixture), accuracy: 1)
        var highlighted = NSRange(location: NSNotFound, length: 0)
        XCTAssertNotNil(fixture.layout.temporaryAttribute(.backgroundColor,
            atCharacterIndex: sourceRange.location, effectiveRange: &highlighted))
        XCTAssertEqual(highlighted, sourceRange)
        XCTAssertEqual(fixture.view.selectedRange(), selection)
        XCTAssertEqual(fixture.view.string, source)
    }

    func testHostedBlankLinePreferenceFoldsInReadingRestoresEditingAndPersistsOriginal() async throws {
        let fixture = try makeHostedFixture()
        defer { fixture.dispose() }
        let source = String(repeating: "保留段落正文与普通换行。\r\n\r\n \t\u{3000}\n\n", count: 30) + "最后一段。"
        fixture.store.text = source
        fixture.store.isEditing = false
        fixture.panel.setFrame(NSRect(x: 100, y: 100, width: 300, height: 360), display: false)
        await settleLayout(fixture.panel)
        let host = try XCTUnwrap(fixture.panel.contentViewController?.view)
        let scroll = try XCTUnwrap(findMemoScrollView(in: host))
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let expandedHeight = layout.usedRect(for: container).height
        let selection = NSRange(location: 0, length: 4)
        view.setSelectedRange(selection)
        XCTAssertFalse(fixture.store.hidesBlankLines)

        fixture.store.hidesBlankLines = true
        await settleLayout(fixture.panel)
        let foldedHeight = layout.usedRect(for: container).height
        XCTAssertLessThan(foldedHeight, expandedHeight)
        XCTAssertGreaterThan(view.frame.height, scroll.contentView.bounds.height)
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 60,
            "The full footer, toggle, and manuscript viewport must remain usable at the minimum width.")
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(view.string, source)

        fixture.store.isEditing = true
        await settleLayout(fixture.panel)
        XCTAssertTrue(view.isEditable)
        XCTAssertTrue(fixture.store.hidesBlankLines, "Editing should preserve the reader's folding preference.")
        XCTAssertEqual(layout.usedRect(for: container).height, expandedHeight, accuracy: 1)
        XCTAssertEqual(view.string, source)

        fixture.store.isEditing = false
        await settleLayout(fixture.panel)
        XCTAssertFalse(view.isEditable)
        XCTAssertEqual(layout.usedRect(for: container).height, foldedHeight, accuracy: 1)
        fixture.store.hidesBlankLines = false
        await settleLayout(fixture.panel)
        XCTAssertEqual(layout.usedRect(for: container).height, expandedHeight, accuracy: 1)
        XCTAssertEqual(fixture.panel.frame.size, NSSize(width: 300, height: 360))

        fixture.store.hidesBlankLines = true
        fixture.store.save()
        let restored = RecorderMemoStore(defaults: fixture.defaults)
        XCTAssertTrue(restored.hidesBlankLines)
        XCTAssertEqual(restored.text, source, "Persistence must retain all source blanks and CRLF characters.")
    }

    func testHostedCompactModeKeepsTextViewSelectionAndHighlightWhileExpandingViewport() async throws {
        let fixture = try makeHostedFixture()
        defer { fixture.dispose() }
        let source = String(repeating: "前面的口播稿段落。\r\n\r\n", count: 25) + "中间👩🏽‍💻的朗读位置。\n继续保持原稿。"
        fixture.store.text = source
        fixture.store.isEditing = false
        shrink(fixture.panel, to: 420)
        await settleLayout(fixture.panel)
        try await settleAnimatedMemoLayout(fixture.panel)
        let host = try XCTUnwrap(fixture.panel.contentViewController?.view)
        let scroll = try XCTUnwrap(findMemoScrollView(in: host))
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let range = (source as NSString).range(of: "中间👩🏽‍💻的朗读位置。")
        view.setSelectedRange(range)
        view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemGreen,
            forCharacterRange: range)
        let fullViewportHeight = scroll.contentView.bounds.height
        let fullFrame = fixture.panel.frame

        fixture.store.setCompact(true)
        await settleLayout(fixture.panel)
        let compactScroll = try XCTUnwrap(findMemoScrollView(in: host))
        let compactView = try XCTUnwrap(compactScroll.documentView as? NSTextView)
        XCTAssertTrue(compactView === view, "Changing chrome must retain the native text editor and its selection/undo state.")
        XCTAssertEqual(fixture.panel.frame, fullFrame, "Switching a sufficiently large window should preserve its frame.")
        // The upstream glyph toolbar uses less chrome, while compact mode
        // still releases the toolbar, speech controls and full-mode footer.
        XCTAssertGreaterThan(compactScroll.contentView.bounds.height, fullViewportHeight + 100)
        XCTAssertFalse(fixture.store.isEditing)
        XCTAssertFalse(compactView.isEditable)
        XCTAssertEqual(compactView.selectedRange(), range)
        XCTAssertEqual(compactView.string, source)
        var highlighted = NSRange(location: NSNotFound, length: 0)
        XCTAssertNotNil(compactView.layoutManager?.temporaryAttribute(.backgroundColor,
            atCharacterIndex: range.location, effectiveRange: &highlighted))
        XCTAssertEqual(highlighted, range, "A display mode change must retain source UTF-16 highlight positions.")
        let color = try XCTUnwrap(compactView.textColor?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThanOrEqual(color.redComponent, 0.9)
        XCTAssertGreaterThanOrEqual(color.greenComponent, 0.9)
        XCTAssertGreaterThanOrEqual(color.blueComponent, 0.9)

        fixture.store.setCompact(false)
        await settleLayout(fixture.panel)
        try await settleAnimatedMemoLayout(fixture.panel)
        let restoredScroll = try XCTUnwrap(findMemoScrollView(in: host))
        XCTAssertTrue(restoredScroll.documentView === view)
        XCTAssertFalse(fixture.store.isEditing, "Leaving compact mode should keep reading mode.")
        XCTAssertEqual(fixture.panel.frame, fullFrame, "Returning to full mode should restore the same window frame.")
        XCTAssertEqual(restoredScroll.contentView.bounds.height, fullViewportHeight, accuracy: 1)
        XCTAssertEqual(view.selectedRange(), range)
        XCTAssertEqual(view.string, source)
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.backgroundColor,
            atCharacterIndex: range.location, effectiveRange: nil))
    }

    func testHostedMemoAppearanceAdaptsWhileCompactTextStaysWhiteAndKeepsReadingState() async throws {
        let fixture = try makeHostedFixture()
        defer { fixture.dispose() }
        let source = "外观切换👩🏽‍💻时，原稿与跟读位置都应保留。"
        fixture.store.text = source
        fixture.store.isEditing = false
        fixture.panel.appearance = NSAppearance(named: .aqua)
        await settleLayout(fixture.panel)
        let host = try XCTUnwrap(fixture.panel.contentViewController?.view)
        let view = try XCTUnwrap(findMemoScrollView(in: host)?.documentView as? NSTextView)
        let range = (source as NSString).range(of: "跟读位置")
        view.setSelectedRange(range)
        view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemGreen,
            forCharacterRange: range)

        let light = try resolvedTextColor(in: view)
        XCTAssertLessThan(light.redComponent, 0.2)
        fixture.panel.appearance = NSAppearance(named: .darkAqua)
        await settleLayout(fixture.panel)
        let dark = try resolvedTextColor(in: view)
        XCTAssertGreaterThan(dark.redComponent, 0.9)

        fixture.store.setCompact(true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            fixture.panel.appearance = NSAppearance(named: appearance)
            await settleLayout(fixture.panel)
            let color = try resolvedTextColor(in: view)
            XCTAssertGreaterThanOrEqual(color.redComponent, 0.9)
            XCTAssertGreaterThanOrEqual(color.greenComponent, 0.9)
            XCTAssertGreaterThanOrEqual(color.blueComponent, 0.9)
        }
        fixture.store.setCompact(false)
        fixture.panel.appearance = NSAppearance(named: .aqua)
        await settleLayout(fixture.panel)
        XCTAssertLessThan(try resolvedTextColor(in: view).redComponent, 0.2)
        XCTAssertTrue(findMemoScrollView(in: host)?.documentView === view)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), range)
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.backgroundColor,
            atCharacterIndex: range.location, effectiveRange: nil))
    }

    func testHostedCompactWindowCanShrinkTo140AndRestoresFullMinimumAtSameTopEdge() async throws {
        let fixture = try makeHostedFixture()
        defer { fixture.dispose() }
        let source = String(repeating: "提词窗口变小仍应保留完整原稿。\n\n", count: 30)
        fixture.store.text = source
        fixture.store.setCompact(true)
        await settleLayout(fixture.panel)
        let host = try XCTUnwrap(fixture.panel.contentViewController?.view)
        let view = try XCTUnwrap(findMemoScrollView(in: host)?.documentView as? NSTextView)
        let top = fixture.panel.frame.maxY
        // NSWindow's minSize getters are ignored under Auto Layout. Exercise
        // a real resize attempt below both required native constraints instead.
        fixture.panel.setFrame(NSRect(x: fixture.panel.frame.minX, y: top - 80, width: 180, height: 80), display: false)
        await settleLayout(fixture.panel)
        XCTAssertEqual(fixture.panel.frame.size, NSSize(width: 240, height: 140))
        XCTAssertEqual(fixture.panel.frame.maxY, top, accuracy: 1)
        let compactScroll = try XCTUnwrap(findMemoScrollView(in: host))
        XCTAssertGreaterThan(compactScroll.contentView.bounds.height, 90,
            "The minimum compact panel should reserve almost all of its height for the manuscript.")
        XCTAssertGreaterThan(view.frame.height, compactScroll.contentView.bounds.height)
        XCTAssertEqual(view.string, source)

        fixture.store.setCompact(false)
        await settleLayout(fixture.panel)
        XCTAssertGreaterThanOrEqual(fixture.panel.frame.width, 300)
        XCTAssertGreaterThanOrEqual(fixture.panel.frame.height, 340)
        XCTAssertEqual(fixture.panel.frame.maxY, top, accuracy: 1,
            "Returning to full mode should grow downward instead of moving the top edge.")
        fixture.panel.setFrame(NSRect(x: fixture.panel.frame.minX, y: top - 180, width: 200, height: 180), display: false)
        await settleLayout(fixture.panel)
        XCTAssertEqual(fixture.panel.frame.size, NSSize(width: 300, height: 340),
            "A full-mode resize attempt below its minimum must be clamped by the actual window constraints.")
        XCTAssertEqual(fixture.panel.frame.maxY, top, accuracy: 1)
        XCTAssertTrue(findMemoScrollView(in: host)?.documentView === view)
        XCTAssertEqual(fixture.store.text, source)
        XCTAssertEqual(view.string, source)
    }

    func testHostedCompactOpacityZeroProducesTransparentTextBackdrop() async throws {
        let fixture = try makeHostedFixture()
        defer { fixture.dispose() }
        let source = "透明提词"
        fixture.store.text = source
        fixture.store.setCompact(true)
        fixture.store.compactOpacity = 0.2
        shrink(fixture.panel, to: 180)
        await settleLayout(fixture.panel)
        let host = try XCTUnwrap(fixture.panel.contentViewController?.view)
        let view = try XCTUnwrap(findMemoScrollView(in: host)?.documentView as? NSTextView)
        let initialAlpha = try backgroundAlpha(in: host)
        XCTAssertGreaterThan(initialAlpha, 0.05,
            "The initial compact background must be visible so this snapshot check can detect transparency.")

        fixture.store.compactOpacity = 0
        await settleLayout(fixture.panel)
        XCTAssertLessThanOrEqual(try backgroundAlpha(in: host), 0.01,
            "Zero opacity should leave the manuscript background transparent.")
        XCTAssertFalse(view.drawsBackground)
        XCTAssertFalse(try XCTUnwrap(findMemoScrollView(in: host)).drawsBackground)
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(findMemoScrollView(in: host)?.documentView === view)
    }

    func testCompactPreferencesPersistWithOriginalManuscriptAndBothOpacityEdges() throws {
        let fixture = try makeHostedFixture()
        defer { fixture.dispose() }
        XCTAssertFalse(fixture.store.isCompact)
        XCTAssertEqual(fixture.store.compactOpacity, 0.2, accuracy: 0.001)
        let source = "原稿👩🏽‍💻\r\n\r\n \t\u{3000}\n完整保留。"
        fixture.store.text = source
        fixture.store.setCompact(true)
        fixture.store.compactOpacity = 0
        fixture.store.save()
        let restored = RecorderMemoStore(defaults: fixture.defaults)
        XCTAssertTrue(restored.isCompact)
        XCTAssertEqual(restored.compactOpacity, 0, accuracy: 0.001)
        XCTAssertFalse(restored.isEditing)
        XCTAssertEqual(restored.text, source)

        fixture.store.setCompact(false)
        fixture.store.compactOpacity = 1
        fixture.store.save()
        let restoredFull = RecorderMemoStore(defaults: fixture.defaults)
        XCTAssertFalse(restoredFull.isCompact)
        XCTAssertFalse(fixture.store.isEditing)
        XCTAssertEqual(restoredFull.compactOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(restoredFull.text, source)
    }

    private func resolvedTextColor(in view: NSTextView) throws -> NSColor {
        var color: NSColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = view.textColor?.usingColorSpace(.deviceRGB)
        }
        return try XCTUnwrap(color)
    }

    private func backgroundAlpha(in view: NSView) throws -> CGFloat {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent
    }

    private func applyMemoParagraphStyle(to view: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 22 * 0.35
        paragraph.paragraphSpacing = 22 * 0.5
        view.defaultParagraphStyle = paragraph
        view.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: (view.string as NSString).length))
    }

    private func lineRect(for text: String, fixture: Fixture) -> NSRect {
        let range = (fixture.view.string as NSString).range(of: text)
        let glyphs = fixture.layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return fixture.layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
    }

    private func makeHostedFixture() throws -> HostedFixture {
        _ = NSApplication.shared
        let domain = "DogSC.RecorderMemoUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let store = RecorderMemoStore(defaults: defaults)
        let speech = RecorderMemoSpeechController()
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 390, height: 890),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentMinSize = NSSize(width: 300, height: 340)
        panel.contentMaxSize = NSSize(width: 760, height: 1000)
        // Exercise the production NSHostingController and the full memo VStack,
        // including the header, speech controls, text viewport, and footer.
        panel.contentViewController = RecorderMemoController.makeContentViewController(
            store: store, speech: speech, onClose: {})
        panel.setFrame(NSRect(x: 100, y: 100, width: 390, height: 890), display: false)
        return HostedFixture(store: store, panel: panel, defaults: defaults, domain: domain)
    }

    private func shrink(_ panel: NSPanel, to height: CGFloat) {
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: false)
    }

    private func settleLayout(_ panel: NSPanel) async {
        // SwiftUI state propagation and representable frame updates occur on
        // subsequent main-actor turns even when the NSPanel is never shown.
        for _ in 0..<3 {
            panel.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func settleAnimatedMemoLayout(_ panel: NSPanel) async throws {
        let host = try XCTUnwrap(panel.contentViewController?.view)
        let scroll = try XCTUnwrap(findMemoScrollView(in: host))
        var previousFrame = panel.frame
        var previousViewport = scroll.contentView.bounds
        var stableSamples = 0
        // Reading mode starts the upstream spring. Sampling after only the
        // usual SwiftUI update turns can capture a viewport mid-animation.
        // Require 200 ms of unchanged geometry, bounded at two seconds.
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            let frame = panel.frame
            let viewport = scroll.contentView.bounds
            if frame == previousFrame && viewport == previousViewport {
                stableSamples += 1
                if stableSamples >= 5 { return }
            } else {
                stableSamples = 0
            }
            previousFrame = frame
            previousViewport = viewport
        }
        XCTFail("The memo window and reading viewport should settle after the editing-mode animation.")
    }

    private func findMemoScrollView(in view: NSView) -> RecorderMemoTextView.MemoScrollView? {
        if let scroll = view as? RecorderMemoTextView.MemoScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findMemoScrollView(in: child) { return scroll }
        }
        return nil
    }

    @MainActor
    private struct HostedFixture {
        let store: RecorderMemoStore
        let panel: NSPanel
        let defaults: UserDefaults
        let domain: String

        func dispose() {
            panel.contentViewController = nil
            panel.close()
            store.save()
            defaults.removePersistentDomain(forName: domain)
        }
    }

    private func makeFixture(_ text: String) -> Fixture {
        _ = NSApplication.shared
        let scroll = RecorderMemoTextView.MemoScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        let storage = NSTextStorage(string: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 292, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = UndoTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), textContainer: container)
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 22)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        container.widthTracksTextView = true
        scroll.documentView = view
        scroll.layoutSubtreeIfNeeded()
        view.setFrameSize(NSSize(width: scroll.contentSize.width, height: 180))
        layout.ensureLayout(for: container)
        let height = max(layout.usedRect(for: container).maxY + view.textContainerInset.height * 2, scroll.contentSize.height)
        view.setFrameSize(NSSize(width: scroll.contentSize.width, height: height))
        let coordinator = RecorderMemoTextView.Coordinator(text: .constant(text),
            selectedRange: .constant(NSRange(location: 0, length: 0)))
        view.delegate = coordinator
        scroll.onUserScroll = { [weak coordinator] in coordinator?.cancelScrollAnimation() }
        return Fixture(view: view, scroll: scroll, layout: layout, container: container, coordinator: coordinator)
    }

    private func expectedTailScrollOrigin(_ range: NSRange, fixture: Fixture) -> CGFloat {
        let tail = (fixture.view.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)
        let glyph = fixture.layout.glyphRange(forCharacterRange: tail, actualCharacterRange: nil)
        let line = fixture.layout.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
        let viewport = fixture.scroll.contentView.bounds.height
        return min(max(line.minY + fixture.view.textContainerInset.height - viewport / 3, 0),
                   max(fixture.view.bounds.height - viewport, 0))
    }

    private struct Fixture {
        let view: UndoTextView
        let scroll: RecorderMemoTextView.MemoScrollView
        let layout: NSLayoutManager
        let container: NSTextContainer
        let coordinator: RecorderMemoTextView.Coordinator
    }

    private final class UndoTextView: NSTextView {
        let testUndoManager: UndoManager = {
            let manager = UndoManager()
            manager.groupsByEvent = false
            return manager
        }()
        override var undoManager: UndoManager? { testUndoManager }
    }
}
