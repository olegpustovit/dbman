import SwiftUI

/// Huge light numeral with a caps label.
public struct Readout: View {
    public enum Size { case s, m, l, xl }
    let value: String, label: String, tail: String?, size: Size
    public init(value: String, label: String, tail: String? = nil, size: Size = .m) {
        self.value = value; self.label = label; self.tail = tail; self.size = size
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            CapsLabel(label, tail).foregroundStyle(HT.C.ink3)
            Text(value).ht(font).foregroundStyle(HT.C.ink).lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(HT.Motion.roll, value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label).accessibilityValue(value)
    }
    private var font: HTFont {
        switch size { case .s: .readoutS; case .m: .readoutM; case .l: .readoutL; case .xl: .readoutXL }
    }
}

#Preview {
    HStack(alignment: .bottom, spacing: 24) {
        Readout(value: "35.51m", label: "Records", size: .xl)
        Readout(value: "290,198", label: "Rows", tail: "Live", size: .l)
        Readout(value: "412", label: "TX/s", size: .m)
        Readout(value: "4 ms", label: "Latency", size: .s)
    }.padding().background(HT.C.paper)
}
