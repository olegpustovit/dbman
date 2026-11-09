import SwiftUI

/// 28pt vertical rail of boxed view numbers; ⌘1…⌘9 select.
public struct NumberRail: View {
    let items: [(number: String, title: String)]
    @Binding var selection: Int
    public init(items: [(number: String, title: String)], selection: Binding<Int>) { self.items = items; _selection = selection }
    public var body: some View {
        VStack(spacing: HT.M.gap) {
            ForEach(items.indices, id: \.self) { i in
                let on = i == selection
                Button { withAnimation(HT.Motion.snap) { selection = i } } label: {
                    Text(items[i].number)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(on ? HT.C.paper : HT.C.ink)
                        .frame(width: 22, height: 22)
                        .background(on ? HT.C.ink : .clear, in: RoundedRectangle(cornerRadius: HT.M.radius))
                        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(on ? HT.C.ink : HT.C.line, lineWidth: 1))
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
