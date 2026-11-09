import SwiftUI

/// White paper panel: 1pt line border, radius 3, 26pt header (caps title left, accessory right).
public struct HTFrame<Accessory: View, Content: View>: View {
    let title: String, tail: String?
    let accessory: Accessory, content: Content
    public init(title: String, tail: String? = nil,
                @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title; self.tail = tail; self.accessory = accessory(); self.content = content()
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: HT.M.gap) {
                CapsLabel(title, tail)
                Spacer(minLength: HT.M.gap)
                accessory
            }
            .padding(.horizontal, 8)
            .frame(height: HT.M.frameHeader)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isHeader)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(HT.C.paper, in: RoundedRectangle(cornerRadius: HT.M.radius))
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: HT.M.radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension HTFrame where Accessory == EmptyView {
    public init(title: String, tail: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, tail: tail, accessory: { EmptyView() }, content: content)
    }
}

/// Backdrop colour with an 8pt dot grid.
public struct DotGridBackground: View {
    public init() {}
    public var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for x in stride(from: CGFloat(4), to: size.width, by: 8) {
                for y in stride(from: CGFloat(4), to: size.height, by: 8) {
                    p.addRect(CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
                }
            }
            ctx.fill(p, with: .color(HT.C.ink.opacity(0.12)))
        }
        .background(HT.C.backdrop)
        .accessibilityHidden(true)
    }
}

#Preview {
    HTFrame(title: "Records", tail: "Live", accessory: { Text("⌘R").ht(.labelSmall) }) {
        Text("content").padding(8)
    }
    .frame(width: 260, height: 120).padding(20).background(DotGridBackground())
}
