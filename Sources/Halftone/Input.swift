import SwiftUI

/// Text-field chrome: plain field in a 1pt hairline box, 26pt tall.
public struct HTInputBox: ViewModifier {
    var stroke: Color
    var weight: CGFloat
    public init(stroke: Color = HT.C.line, weight: CGFloat = 1) { self.stroke = stroke; self.weight = weight }
    public func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(stroke, lineWidth: weight))
    }
}

extension View {
    public func htInput(stroke: Color = HT.C.line, weight: CGFloat = 1) -> some View { modifier(HTInputBox(stroke: stroke, weight: weight)) }
}
