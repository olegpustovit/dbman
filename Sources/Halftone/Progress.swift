import SwiftUI

// Progress primitives (States 01, Motion 05): silent under 400 ms, then a 3×3 dot spinner, live elapsed time and,
// for multi-stage work, a step list that says what is happening, what finished and how long each part took.

/// 3×3 square dots; a bright head runs round the ring with a fading tail. Reduce Motion: a static ring.
public struct DotSpinner: View {
    let dot: CGFloat, gap: CGFloat, tint: Color
    /// Ring order (row-major indices) clockwise from the top-left; the centre stays dim.
    private static let ring = [0, 1, 2, 5, 8, 7, 6, 3]
    private static let tail: [Double] = [1, 0.72, 0.5, 0.34, 0.22, 0.16, 0.14, 0.14]
    public init(dot: CGFloat = 5, gap: CGFloat = 2, tint: Color = HT.C.ink) { self.dot = dot; self.gap = gap; self.tint = tint }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.09)) { ctx in
            let head = HT.Motion.reduce ? 0 : Int(ctx.date.timeIntervalSinceReferenceDate / 0.09) % 8
            Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                ForEach(0..<3, id: \.self) { r in
                    GridRow {
                        ForEach(0..<3, id: \.self) { c in
                            Rectangle().fill(tint).frame(width: dot, height: dot).opacity(opacity(r * 3 + c, head: head))
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func opacity(_ i: Int, head: Int) -> Double {
        guard let pos = Self.ring.firstIndex(of: i) else { return 0.14 }
        return Self.tail[(head - pos + 8) % 8]
    }
}

/// Live seconds since `since`: `0.8 S`, `12 S`, `1:04`. Rolls like a readout.
public struct ElapsedText: View {
    let since: Date, font: HTFont, tint: Color
    public init(since: Date, font: HTFont = .labelSmall, tint: Color = HT.C.ink3) { self.since = since; self.font = font; self.tint = tint }
    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            Text(Self.format(ctx.date.timeIntervalSince(since))).ht(font).foregroundStyle(tint).monospacedDigit()
        }
        .accessibilityLabel("Elapsed")
    }
    public static func format(_ s: TimeInterval) -> String {
        let s = max(0, s)
        if s < 10 { return String(format: "%.1f S", s) }
        if s < 60 { return "\(Int(s)) S" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
    public static func ms(_ ms: Int) -> String { ms < 1000 ? "\(ms) MS" : format(Double(ms) / 1000) }
}

/// Shows its content only once the work has run for 400 ms (Doherty), then enters (offset 6 + fade).
public struct LateReveal<Content: View>: View {
    let delay: Duration, content: Content
    @State private var shown = false
    public init(after delay: Duration = .milliseconds(400), @ViewBuilder content: () -> Content) { self.delay = delay; self.content = content() }
    public var body: some View {
        content
            .opacity(shown ? 1 : 0).offset(y: shown || HT.Motion.reduce ? 0 : 6)
            .task { try? await Task.sleep(for: delay); withAnimation(HT.Motion.enter) { shown = true } }
    }
}

// MARK: - Steps

public enum HTStepState: Equatable, Sendable {
    case pending
    case active(since: Date)
    case done(ms: Int)
    case failed(ms: Int)
    case skipped
    public var isActive: Bool { if case .active = self { return true } else { return false } }
}

public struct HTStep: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var detail: String
    public var state: HTStepState
    public init(id: String, title: String, detail: String, state: HTStepState = .pending) { self.id = id; self.title = title; self.detail = detail; self.state = state }
}

/// One line per stage: glyph · TITLE + mono detail · timing. Active = spinner + live time (accent), done = solid square + ms,
/// failed = alert square, pending = outline. Rows are separated by hairlines like the grid.
public struct HTStepList: View {
    let steps: [HTStep]
    public init(_ steps: [HTStep]) { self.steps = steps }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                row(s, index: i)
                if i < steps.count - 1 { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
        .animation(HT.Motion.snap, value: steps)
    }

    private func row(_ s: HTStep, index: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(String(format: "%02d", index + 1)).ht(.dataSmall).foregroundStyle(HT.C.ink3).frame(width: 18, alignment: .leading)
            glyph(s.state).frame(width: 13, height: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).ht(.label).foregroundStyle(titleTint(s.state))
                Text(s.detail).ht(.dataSmall).foregroundStyle(detailTint(s.state)).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(s.detail)
                    .contentTransition(.identity).transaction { $0.animation = nil } // live detail swaps instantly; no cross-fade ghosting
            }
            Spacer(minLength: 8)
            timing(s.state)
        }
        .padding(.vertical, 8)
        .frame(height: 44) // fixed: details changing length never shift the rows below
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(s.title), \(Self.spoken(s.state))")
        .accessibilityValue(s.detail)
    }

    @ViewBuilder private func glyph(_ st: HTStepState) -> some View {
        switch st {
        case .pending: Rectangle().strokeBorder(HT.C.fill30, lineWidth: 1).frame(width: 9, height: 9)
        case .active: DotSpinner(dot: 3, gap: 1, tint: HT.C.accent)
        case .done: Rectangle().fill(HT.C.ink).frame(width: 9, height: 9)
        case .failed: Rectangle().fill(HT.C.alert).frame(width: 9, height: 9)
        case .skipped: Rectangle().fill(HT.C.line).frame(width: 9, height: 1)
        }
    }

    @ViewBuilder private func timing(_ st: HTStepState) -> some View {
        switch st {
        case .active(let since): ElapsedText(since: since, font: .label, tint: HT.C.accent)
        case .done(let ms): Text(ElapsedText.ms(ms)).ht(.labelSmall).foregroundStyle(HT.C.ink3)
        case .failed(let ms): Text("FAILED · \(ElapsedText.ms(ms))").ht(.labelSmall).foregroundStyle(HT.C.alert)
        case .skipped: Text("SKIPPED").ht(.labelSmall).foregroundStyle(HT.C.ink3)
        case .pending: Text("WAITING").ht(.labelSmall).foregroundStyle(HT.C.fill30)
        }
    }

    private func titleTint(_ st: HTStepState) -> Color {
        switch st { case .pending, .skipped: HT.C.ink3; case .active: HT.C.accent; case .done: HT.C.ink; case .failed: HT.C.alert }
    }
    private func detailTint(_ st: HTStepState) -> Color {
        switch st { case .pending, .skipped: HT.C.ink3; case .failed: HT.C.alert; default: HT.C.ink2 }
    }
    static func spoken(_ st: HTStepState) -> String {
        switch st {
        case .pending: "waiting"
        case .active: "in progress"
        case .done(let ms): "done in \(ms) milliseconds"
        case .failed: "failed"
        case .skipped: "skipped"
        }
    }
}

/// A one-line running strip for in-place loads: spinner · LABEL // detail · elapsed · optional action. Appears after 400 ms.
public struct HTLoadingStrip<Action: View>: View {
    let label: String, detail: String?, since: Date, action: Action
    public init(_ label: String, detail: String? = nil, since: Date, @ViewBuilder action: () -> Action) {
        self.label = label; self.detail = detail; self.since = since; self.action = action()
    }
    public var body: some View {
        LateReveal {
            HStack(spacing: 10) {
                DotSpinner()
                CapsLabel(label, detail)
                Spacer(minLength: 8)
                ElapsedText(since: since, font: .label, tint: HT.C.ink2)
                action
            }
            .padding(.horizontal, 10).frame(height: 34)
            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.fill30, lineWidth: 1))
            .accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
        }
    }
}

extension HTLoadingStrip where Action == EmptyView {
    public init(_ label: String, detail: String? = nil, since: Date) { self.init(label, detail: detail, since: since) { EmptyView() } }
}

#Preview {
    let now = Date()
    VStack(alignment: .leading, spacing: 16) {
        HTLoadingStrip("Running", detail: "streaming rows", since: now)
        HTStepList([
            HTStep(id: "a", title: "SSH tunnel", detail: "ubuntu@cx2-satdb → 127.0.0.1:5455", state: .done(ms: 412)),
            HTStep(id: "b", title: "Handshake", detail: "postgres · TLS prefer · phenix@satellite_launches", state: .active(since: now)),
            HTStep(id: "c", title: "Read schema", detail: "tables, columns, keys"),
        ])
    }.padding().frame(width: 520).background(HT.C.paper)
}
