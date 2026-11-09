import AppKit
import DBCore
import Halftone
import SwiftUI

struct GridColumn: Hashable {
    var name: String
    var type: String = ""
    var isPrimaryKey = false
    var isForeignKey = false
    var alignRight = false
}

/// Tracker-style grid: NSTableView with view-based, reused cells; no per-row SwiftUI.
struct DataGrid: NSViewRepresentable {
    var columns: [GridColumn]
    var rows: [[Cell]]
    var selection: Binding<Int?>
    var focusedColumn: Binding<Int>
    var sparklines: [String: [Double]] = [:]
    var onSort: ((String) -> Void)? = nil
    var onEdit: ((Int, Int) -> Void)? = nil
    var onFilterValue: ((String, Cell) -> Void)? = nil
    var onFollowFK: ((Int, Int) -> Void)? = nil
    var onReachEnd: (() -> Void)? = nil
    var tableName = "table"   // only used by "Copy as INSERT"
    var markedRows: Set<Int> = []  // rows with staged changes: amber gutter bar

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let t = GridTableView()
        t.style = .plain
        t.rowHeight = HT.M.row
        t.intercellSpacing = .zero
        t.gridStyleMask = []
        t.backgroundColor = HT.NS.paper
        t.usesAlternatingRowBackgroundColors = false
        t.allowsMultipleSelection = false
        t.allowsColumnReordering = false
        t.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 26))
        t.dataSource = c
        t.delegate = c
        t.target = c
        t.doubleAction = #selector(Coordinator.doubleClicked)
        t.setAccessibilityLabel("Query results")
        c.table = t
        t.moveFocus = { [unowned c] d in c.setFocus(c.focus + d) }
        t.focusAt = { [unowned c] col in c.setFocus(col - 1) }
        t.activate = { [unowned c] in c.edit(row: c.table.selectedRow, col: c.focus) }
        t.copySel = { [unowned c] in c.copy(.tsv) }
        t.menuFor = { [unowned c] r, col in c.menu(row: r, col: col) }
        let sv = NSScrollView()
        sv.documentView = t
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.drawsBackground = true
        sv.backgroundColor = HT.NS.paper
        c.update(self)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) { context.coordinator.update(self) }

    // MARK: Coordinator

    enum CopyFormat { case tsv, json, insert }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var p: DataGrid
        weak var table: GridTableView!
        var rows: [[Cell]] = []
        var cols: [GridColumn] = []
        var sparks: [String: [Double]] = [:]
        var focus = 0
        var syncing = false
        var lastSel = -1
        var endRequestedAt = -1
        var ctx = (row: 0, col: 0)

        init(_ p: DataGrid) { self.p = p }

        func update(_ p: DataGrid) {
            self.p = p
            syncing = true
            defer { syncing = false }
            focus = p.focusedColumn.wrappedValue
            if p.columns != cols {
                cols = p.columns; rows = p.rows
                rebuildColumns()
                table.reloadData()
                endRequestedAt = -1
            } else if p.rows != rows { // identical array buffers compare in O(1)
                let old = rows
                rows = p.rows
                if !old.isEmpty, rows.count > old.count, rows[0] == old[0], rows[old.count - 1] == old[old.count - 1] {
                    table.insertRows(at: IndexSet(old.count..<rows.count), withAnimation: [])
                } else {
                    table.reloadData()
                    endRequestedAt = -1
                }
            }
            if p.sparklines != sparks {
                sparks = p.sparklines
                for tc in table.tableColumns { (tc.headerCell as? GridHeaderCell)?.spark = sparks[tc.title] ?? [] }
                table.headerView?.needsDisplay = true
            }
            let want = p.selection.wrappedValue.flatMap { $0 < rows.count ? $0 : nil }
            if want != (table.selectedRow >= 0 ? table.selectedRow : nil) {
                if let w = want { table.selectRowIndexes([w], byExtendingSelection: false); table.scrollRowToVisible(w) }
                else { table.deselectAll(nil) }
            }
            refresh(rows: [lastSel, table.selectedRow])
            lastSel = table.selectedRow
        }

        func rebuildColumns() {
            for c in table.tableColumns { table.removeTableColumn(c) }
            func add(_ id: String, _ title: String, _ w: CGFloat, fixed: Bool) {
                let c = NSTableColumn(identifier: .init(id))
                let h = GridHeaderCell(textCell: title)
                h.isGutter = fixed
                c.headerCell = h
                c.title = title
                c.width = w; c.minWidth = fixed ? w : 60
                if fixed { c.maxWidth = w; c.resizingMask = [] } else { c.resizingMask = .userResizingMask }
                table.addTableColumn(c)
            }
            add("L", "", 48, fixed: true)
            for (i, col) in cols.enumerated() { add("c\(i)", col.name, contentWidth(i, col), fixed: false) }
            add("R", "", 48, fixed: true)
        }

        /// Header and first 60 values in SF Mono 12 (~7.3 pt/char) + padding, clamped.
        func contentWidth(_ i: Int, _ col: GridColumn) -> CGFloat {
            let longest = rows.prefix(60).reduce(col.name.count + 3) { max($0, i < $1.count ? $1[i].display.count : 0) }
            return min(320, max(64, CGFloat(longest) * 7.3 + 20))
        }

        func refresh(rows r: [Int]) {
            let idx = IndexSet(r.filter { $0 >= 0 && $0 < rows.count })
            if !idx.isEmpty { table.reloadData(forRowIndexes: idx, columnIndexes: IndexSet(0..<table.numberOfColumns)) }
        }

        func setFocus(_ c: Int) {
            let n = max(0, min(cols.count - 1, c))
            guard n != focus else { return }
            focus = n
            p.focusedColumn.wrappedValue = n
            refresh(rows: [table.selectedRow])
        }

        func dataIndex(_ tc: NSTableColumn?) -> Int? {
            guard let id = tc?.identifier.rawValue, id.hasPrefix("c") else { return nil }
            return Int(id.dropFirst())
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let v = tableView.makeView(withIdentifier: GridRowView.id, owner: nil) as? GridRowView ?? GridRowView()
            v.identifier = GridRowView.id
            v.isMarked = p.markedRows.contains(row)
            return v
        }

        func tableView(_ tableView: NSTableView, viewFor tc: NSTableColumn?, row: Int) -> NSView? {
            guard let tc, row < rows.count else { return nil }
            let v = tableView.makeView(withIdentifier: GridCellView.id, owner: nil) as? GridCellView ?? GridCellView()
            v.identifier = GridCellView.id
            if row >= rows.count - 15, endRequestedAt != rows.count {
                endRequestedAt = rows.count
                DispatchQueue.main.async { [weak self] in self?.p.onReachEnd?() }
            }
            let id = tc.identifier.rawValue
            if id == "L" || id == "R" {
                v.set(String(row + 1), font: GridFonts.gutter, color: HT.NS.ink3, right: id == "L", label: "Row \(row + 1)")
            } else if let i = dataIndex(tc), i < cols.count, i < rows[row].count {
                let cell = rows[row][i], col = cols[i]
                let focused = row == table.selectedRow && i == focus
                v.set(cell: cell, column: col, focused: focused)
            }
            return v
        }

        func tableViewSelectionDidChange(_ n: Notification) {
            let s = table.selectedRow
            refresh(rows: [lastSel, s])
            lastSel = s
            if !syncing { p.selection.wrappedValue = s >= 0 ? s : nil }
        }

        func tableView(_ tableView: NSTableView, didClick tc: NSTableColumn) {
            if let i = dataIndex(tc) { p.onSort?(cols[i].name) }
        }

        @objc func doubleClicked() {
            if let i = dataIndex(table.clickedColumn >= 0 ? table.tableColumns[table.clickedColumn] : nil) { edit(row: table.clickedRow, col: i) }
        }

        func edit(row: Int, col: Int) { if row >= 0, col >= 0, col < cols.count { p.onEdit?(row, col) } }

        // MARK: Copy / menu

        func text(_ format: CopyFormat, rowIdx: [Int]) -> String {
            let sel = rowIdx.filter { $0 < rows.count }.map { rows[$0] }
            switch format {
            case .tsv:
                return sel.map { $0.map { $0.isNull ? "" : $0.display.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }.joined(separator: "\n")
            case .json:
                func j(_ c: Cell) -> String {
                    let o: Any
                    switch c {
                    case .null: o = NSNull()
                    case .integer(let v): o = v
                    case .real(let v): o = v.isFinite ? v : NSNull()
                    case .bool(let v): o = v
                    default: o = c.display
                    }
                    return (try? JSONSerialization.data(withJSONObject: o, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                }
                let objs = sel.map { r in "  {" + zip(cols, r).map { "\(j(.text($0.name))): \(j($1))" }.joined(separator: ", ") + "}" }
                return "[\n" + objs.joined(separator: ",\n") + "\n]"
            case .insert:
                let names = cols.map { "\"\($0.name)\"" }.joined(separator: ", ")
                return sel.map { "INSERT INTO \"\(p.tableName)\" (\(names)) VALUES (" + $0.map(\.sqlLiteral).joined(separator: ", ") + ");" }.joined(separator: "\n")
            }
        }

        func copy(_ f: CopyFormat) {
            let s = text(f, rowIdx: Array(table.selectedRowIndexes))
            guard !s.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }

        func menu(row: Int, col: Int) -> NSMenu {
            ctx = (row, col - 1)
            let m = NSMenu()
            func add(_ t: String, _ s: Selector) { let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; m.addItem(i) }
            add("Copy as TSV", #selector(copyTSV)); add("Copy as JSON", #selector(copyJSON)); add("Copy as INSERT", #selector(copyInsert))
            if ctx.col >= 0, ctx.col < cols.count, ctx.row < rows.count, ctx.col < rows[ctx.row].count {
                m.addItem(.separator())
                if p.onFilterValue != nil { add("Filter by this value", #selector(filterValue)) }
                if cols[ctx.col].isForeignKey, !rows[ctx.row][ctx.col].isNull, p.onFollowFK != nil { add("Follow foreign key", #selector(followFK)) }
            }
            return m
        }

        @objc func copyTSV() { copy(.tsv) }
        @objc func copyJSON() { copy(.json) }
        @objc func copyInsert() { copy(.insert) }
        @objc func filterValue() { p.onFilterValue?(cols[ctx.col].name, rows[ctx.row][ctx.col]) }
        @objc func followFK() { p.onFollowFK?(ctx.row, ctx.col) }
    }
}

// MARK: - AppKit pieces

enum GridFonts {
    static let value = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let gutter = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let null: NSFont = {
        let base = NSFont.systemFont(ofSize: 12)
        let d = base.fontDescriptor.withDesign(.serif)?.withSymbolicTraits(.italic) ?? base.fontDescriptor
        return NSFont(descriptor: d, size: 12) ?? base
    }()
    static let header: NSFont = {
        let d = NSFont.systemFont(ofSize: 11, weight: .semibold).fontDescriptor
            .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue, NSFontDescriptor.TraitKey.width: -0.3]])
        return NSFont(descriptor: d, size: 11) ?? .systemFont(ofSize: 11, weight: .semibold)
    }()
}

final class GridTableView: NSTableView {
    var moveFocus: ((Int) -> Void)?
    var focusAt: ((Int) -> Void)?
    var activate: (() -> Void)?
    var copySel: (() -> Void)?
    var menuFor: ((Int, Int) -> NSMenu?)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 123: moveFocus?(-1)
        case 124: moveFocus?(1)
        case 36, 76: activate?()
        default: super.keyDown(with: e)
        }
    }

    override func mouseDown(with e: NSEvent) {
        let c = column(at: convert(e.locationInWindow, from: nil))
        if c >= 0 { focusAt?(c) }
        super.mouseDown(with: e)
    }

    @objc func copy(_ sender: Any?) { copySel?() }

    override func menu(for e: NSEvent) -> NSMenu? {
        let pt = convert(e.locationInWindow, from: nil)
        let r = row(at: pt), c = column(at: pt)
        guard r >= 0 else { return nil }
        selectRowIndexes([r], byExtendingSelection: false)
        if c >= 0 { focusAt?(c) }
        return menuFor?(r, c)
    }
}

final class GridRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("gridRow")
    override var isEmphasized: Bool { get { true } set {} }
    var isMarked = false { didSet { if isMarked != oldValue { needsDisplay = true } } }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isMarked { HT.NS.amber.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill() }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        HT.NS.fill12.setFill(); bounds.fill()
        HT.NS.ink.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

final class GridCellView: NSView {
    static let id = NSUserInterfaceItemIdentifier("gridCell")
    private var text = NSAttributedString()
    private var lineH: CGFloat = 14
    private var inverted = false

    override var isFlipped: Bool { true }

    func set(_ s: String, font: NSFont, color: NSColor, right: Bool, label: String) {
        let ps = NSMutableParagraphStyle()
        ps.alignment = right ? .right : .left
        ps.lineBreakMode = .byTruncatingTail
        text = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
        lineH = ceil(font.ascender - font.descender + font.leading)
        inverted = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
        needsDisplay = true
    }

    func set(cell: Cell, column: GridColumn, focused: Bool) {
        let isNull = cell.isNull
        let ink = focused ? HT.NS.paper : (isNull ? HT.NS.ink3 : HT.NS.ink)
        set(cell.display, font: isNull ? GridFonts.null : GridFonts.value, color: ink, right: column.alignRight, label: column.name)
        if column.isForeignKey, !isNull, let a = text.mutableCopy() as? NSMutableAttributedString {
            a.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                             .underlineColor: focused ? HT.NS.paper : HT.NS.accent], range: NSRange(location: 0, length: a.length))
            text = a
        }
        inverted = focused
        setAccessibilityLabel(column.name)
        setAccessibilityValue(cell.display)
    }

    override func draw(_ dirtyRect: NSRect) {
        if inverted { HT.NS.ink.setFill(); bounds.fill() }
        text.draw(with: NSRect(x: 8, y: (bounds.height - lineH) / 2, width: bounds.width - 16, height: lineH),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

final class GridHeaderCell: NSTableHeaderCell {
    var spark: [Double] = []
    var isGutter = false

    override func draw(withFrame f: NSRect, in v: NSView) {
        HT.NS.paper.setFill(); f.fill()
        HT.NS.ink.setFill()
        NSRect(x: f.minX, y: v.isFlipped ? f.maxY - 1 : f.minY, width: f.width, height: 1).fill()
        guard !isGutter else { return }
        let s = NSAttributedString(string: stringValue.uppercased(), attributes: [.font: GridFonts.header, .foregroundColor: HT.NS.ink, .kern: 0.9])
        let h = s.size().height
        s.draw(with: NSRect(x: f.minX + 8, y: f.midY - h / 2, width: f.width - 16 - (spark.isEmpty ? 0 : 16), height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        drawSparkline(in: NSRect(x: f.maxX - 20, y: f.midY - 2, width: 12, height: 4), flipped: v.isFlipped)
    }

    /// 12x4 halftone: up to 12 one-point bars, 1...4 pt tall, the latest at full ink.
    private func drawSparkline(in r: NSRect, flipped: Bool) {
        guard let lo = spark.min(), let hi = spark.max() else { return }
        let n = min(12, spark.count), bw = r.width / CGFloat(n)
        for k in 0..<n {
            let v = spark[k * spark.count / n]
            let h = hi > lo ? 1 + CGFloat((v - lo) / (hi - lo)) * 3 : 2
            HT.NS.ink.withAlphaComponent(k == n - 1 ? 1 : 0.55).setFill()
            NSRect(x: r.minX + CGFloat(k) * bw, y: flipped ? r.maxY - h : r.minY, width: max(1, bw - 0.5), height: h).fill()
        }
    }
}
