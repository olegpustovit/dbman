import AppKit
import Halftone
import SwiftUI

struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    var completions: [String]
    var onRunStatement: (String) -> Void
    var onRunAll: (String) -> Void

    init(text: Binding<String>, completions: [String], onRunStatement: @escaping (String) -> Void, onRunAll: @escaping (String) -> Void) {
        _text = text; self.completions = completions; self.onRunStatement = onRunStatement; self.onRunAll = onRunAll
        #if DEBUG
        _ = Self.selfTestOnce
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let tv = EditorTextView(usingTextLayoutManager: true)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.drawsBackground = true
        tv.backgroundColor = HT.NS.paper
        tv.insertionPointColor = HT.NS.accent
        tv.font = SQLStyle.base
        tv.typingAttributes = [.font: SQLStyle.base, .foregroundColor: HT.NS.ink]
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = .width
        tv.setAccessibilityLabel("SQL editor")
        tv.delegate = c
        tv.textStorage?.delegate = c
        tv.onRunStatement = { [unowned c, unowned tv] in
            let sel = tv.selectedRange()
            c.p.onRunStatement(SQLEditor.statement(at: sel.location, in: tv.string))
        }
        tv.onRunAll = { [unowned c, unowned tv] in c.p.onRunAll(tv.string) }
        c.tv = tv
        tv.string = text // fires storage delegate -> highlights

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.drawsBackground = true
        sv.backgroundColor = HT.NS.paper
        let ruler = LineNumberRuler(scrollView: sv, orientation: .verticalRuler)
        ruler.clientView = tv // not set automatically for a custom ruler: without it nothing draws
        sv.verticalRulerView = ruler
        sv.hasVerticalRuler = true
        sv.rulersVisible = true
        sv.contentView.postsBoundsChangedNotifications = true
        for (name, obj) in [(NSText.didChangeNotification, tv as AnyObject), (NSView.boundsDidChangeNotification, sv.contentView)] {
            NotificationCenter.default.addObserver(forName: name, object: obj, queue: .main) { [weak ruler] _ in ruler?.needsDisplay = true }
        }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.p = self
        if let tv = c.tv, tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var p: SQLEditor
        weak var tv: EditorTextView?
        var typedWordChar = false
        init(_ p: SQLEditor) { self.p = p }

        func textDidChange(_ n: Notification) {
            guard let tv else { return }
            if p.text != tv.string { p.text = tv.string }
            if typedWordChar, partialWord(in: tv).length >= 2 { DispatchQueue.main.async { tv.complete(nil) } }
        }

        func textView(_ tv: NSTextView, shouldChangeTextIn r: NSRange, replacementString s: String?) -> Bool {
            typedWordChar = s?.count == 1 && s!.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            return true
        }

        func partialWord(in tv: NSTextView) -> NSRange {
            tv.rangeForUserCompletion
        }

        func textView(_ tv: NSTextView, completions words: [String], forPartialWordRange r: NSRange, indexOfSelectedItem i: UnsafeMutablePointer<Int>?) -> [String] {
            let w = (tv.string as NSString).substring(with: r).lowercased()
            guard !w.isEmpty else { return [] }
            return p.completions.filter { $0.lowercased().hasPrefix(w) && $0.lowercased() != w }.sorted()
        }

        /// Re-highlights only the paragraphs touched by the edit.
        func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
            guard mask.contains(.editedCharacters) else { return }
            SQLStyle.highlight(ts, in: (ts.string as NSString).paragraphRange(for: range))
        }
    }

    // MARK: Statement splitting

    /// The statement under `cursor` (UTF-16 offset), splitting on top-level `;` and ignoring ones in quotes/comments.
    static func statement(at cursor: Int, in text: String) -> String {
        let u = Array(text.utf16)
        var spans: [(Int, Int)] = []   // [start, end) of each statement, `;` excluded
        var start = 0, i = 0
        func isBlank(_ a: Int, _ b: Int) -> Bool { u[a..<b].allSatisfy { $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 } }
        while i < u.count {
            let ch = u[i]
            if ch == 39 || ch == 34 || ch == 96 { // ' " `
                i += 1
                while i < u.count && u[i] != ch { i += 1 }
            } else if ch == 45, i + 1 < u.count, u[i + 1] == 45 { // --
                while i < u.count && u[i] != 10 { i += 1 }
            } else if ch == 47, i + 1 < u.count, u[i + 1] == 42 { // /*
                i += 2
                while i + 1 < u.count && !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
                i += 1
            } else if ch == 59 {
                if !isBlank(start, i) { spans.append((start, i + 1)) }
                start = i + 1
            }
            i += 1
        }
        if start < u.count, !isBlank(start, u.count) { spans.append((start, u.count)) }
        guard let s = spans.first(where: { cursor <= $0.1 }) ?? spans.last else { return "" }
        var body = String(decoding: u[s.0..<min(s.1, u.count)], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(";") { body.removeLast() }
        return body
    }

    #if DEBUG
    private static let selfTestOnce: Void = _selfTest()

    static func _selfTest() {
        let t = "select 1;\nselect ';' as a, \"x;y\"; -- c;\nselect 3"
        assert(statement(at: 0, in: t) == "select 1")
        assert(statement(at: 9, in: t) == "select 1")            // right after the `;`
        assert(statement(at: 20, in: t) == "select ';' as a, \"x;y\"")
        assert(statement(at: t.utf16.count, in: t) == "-- c;\nselect 3") // leading comment travels with its statement
        assert(statement(at: 3, in: "") == "")
        assert(statement(at: 5, in: "a /* ; */ b; c") == "a /* ; */ b")
    }
    #endif
}

// MARK: - Highlighting

enum SQLStyle {
    static let base = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let bold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    static let italic: NSFont = {
        let d = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: d, size: 12.5) ?? base
    }()
    static let keywords: Set<String> = Set("""
        select from where and or not in is null like between exists case when then else end as on join left right inner outer full cross \
        group by order having limit offset union all distinct insert into values update set delete create table view index drop alter add \
        column primary key foreign references default unique with recursive returning asc desc explain analyze begin commit rollback \
        pragma if cast over partition using true false
        """.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\\" }).map(String.init))

    /// Tokenises per paragraph, so block comments / strings spanning lines are not tracked.
    /// shortcut: multi-line constructs colour per line only; upgrade by tokenising from statement start.
    static func highlight(_ ts: NSTextStorage, in range: NSRange) {
        let s = ts.string as NSString
        func paint(_ r: NSRange, _ font: NSFont, _ color: NSColor) { ts.addAttributes([.font: font, .foregroundColor: color], range: r) }
        paint(range, base, HT.NS.ink)
        let end = NSMaxRange(range)
        var i = range.location
        func isWord(_ c: unichar) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        while i < end {
            let c = s.character(at: i)
            if c == 45, i + 1 < end, s.character(at: i + 1) == 45 {
                var j = i
                while j < end && s.character(at: j) != 10 { j += 1 } // the range can span several lines (initial set)
                paint(NSRange(location: i, length: j - i), italic, HT.NS.ink3); i = j
            } else if c == 47, i + 1 < end, s.character(at: i + 1) == 42 {
                var j = i + 2
                while j + 1 < end && !(s.character(at: j) == 42 && s.character(at: j + 1) == 47) { j += 1 }
                j = min(end, j + 2)
                paint(NSRange(location: i, length: j - i), italic, HT.NS.ink3); i = j
            } else if c == 39 {
                var j = i + 1
                while j < end && s.character(at: j) != 39 { j += 1 }
                j = min(end, j + 1)
                paint(NSRange(location: i, length: j - i), base, HT.NS.ink2); i = j
            } else if isWord(c) {
                var j = i
                while j < end && isWord(s.character(at: j)) { j += 1 }
                let r = NSRange(location: i, length: j - i)
                if c >= 48 && c <= 57 { paint(r, base, HT.NS.ink2) }
                else if keywords.contains(s.substring(with: r).lowercased()) { paint(r, bold, HT.NS.ink) }
                i = j
            } else { i += 1 }
        }
    }
}

// MARK: - AppKit pieces

final class EditorTextView: NSTextView {
    var onRunStatement: (() -> Void)?
    var onRunAll: (() -> Void)?

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.keyCode == 36 || e.keyCode == 76 {
            let m = e.modifierFlags.intersection([.command, .shift, .option, .control])
            if m == .command { onRunStatement?(); return true }
            if m == [.command, .shift] { onRunAll?(); return true }
        }
        return super.performKeyEquivalent(with: e)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49, e.modifierFlags.intersection([.command, .shift, .option, .control]) == .control { complete(nil); return }
        super.keyDown(with: e)
    }
}

final class LineNumberRuler: NSRulerView {
    override var isFlipped: Bool { true }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 40
    }
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        HT.NS.paper.setFill(); bounds.fill()
        HT.NS.line.setFill(); NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        guard let tv = clientView as? NSTextView, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return }
        // Before the first layout pass there is no viewport yet: start from the top.
        let start = tlm.textViewportLayoutController.viewportRange?.location ?? tcm.documentRange.location
        let ns = tv.string as NSString
        let off = tcm.offset(from: tcm.documentRange.location, to: start)
        // shortcut: counts newlines before the viewport on every draw (O(n)); cache if documents get huge.
        var line = 1
        var k = 0
        while k < min(off, ns.length) { if ns.character(at: k) == 10 { line += 1 }; k += 1 }
        let attrs: [NSAttributedString.Key: Any] = [.font: GridFonts.gutter, .foregroundColor: HT.NS.ink3]
        let maxY = tv.visibleRect.maxY
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { f in
            let lh = f.textLineFragments.first?.typographicBounds.height ?? 15
            let y = self.convert(NSPoint(x: 0, y: f.layoutFragmentFrame.minY + tv.textContainerOrigin.y), from: tv).y
            let s = NSAttributedString(string: String(line), attributes: attrs)
            s.draw(at: NSPoint(x: self.bounds.maxX - 8 - s.size().width, y: y + (lh - s.size().height) / 2))
            line += 1
            return f.layoutFragmentFrame.minY < maxY
        }
    }
}
