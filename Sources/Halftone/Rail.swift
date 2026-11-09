import SwiftUI

/// 28pt vertical rail of named tabs: number + caps title, reading bottom-to-top like a spine label; ⌘1…⌘9 select.
public struct NumberRail: View {
    let items: [(number: String, title: String)]
    @Binding var selection: Int
    public init(items: [(number: String, title: String)], selection: Binding<Int>) { self.items = items; _selection = selection }
    public var body: some View {
        VStack(spacing: HT.M.gap) {
            ForEach(items.indices, id: \.self) { i in
                let on = i == selection
                Button { withAnimation(HT.Motion.snap) { selection = i } } label: {
                    let title = items[i].title.uppercased()
                    let length = CGFloat(items[i].number.count) * 6.6 + CGFloat(title.count) * 6.4 + 22
                    HStack(spacing: 5) {
                        Text(items[i].number).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        Text(title).font(.system(size: 10, weight: .semibold).width(.condensed)).tracking(0.9).opacity(on ? 1 : 0.75)
                    }
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 22, height: length)
                        .foregroundStyle(on ? HT.C.paper : HT.C.ink3)
                        .background(on ? HT.C.ink : .clear, in: RoundedRectangle(cornerRadius: HT.M.radius))
                        // no outline: the active tab is the filled one, the rest are plain labels
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(items[i].title) (⌘\(i + 1))")
                .accessibilityLabel(items[i].title)
                .accessibilityAddTraits(on ? .isSelected : [])
                .keyboardShortcut(i < 9 ? KeyEquivalent(Character("\(i + 1)")) : "0", modifiers: .command)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(width: HT.M.rail)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(HT.C.paper)
        .overlay(Rectangle().strokeBorder(HT.C.line, lineWidth: HT.M.hairline)) // a panel like its neighbours: one shared line, no backdrop showing
    }
}

#Preview {
    struct P: View {
        @State var s = 0
        var body: some View {
            NumberRail(items: [("01", "Overview"), ("02", "Tables"), ("03", "Query"), ("04", "Activity")], selection: $s)
                .frame(height: 160).background(HT.C.backdrop)
        }
    }
    return P()
}
