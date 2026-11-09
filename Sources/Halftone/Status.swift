import SwiftUI

/// Colour meaning: normal = ink, amber = pending/attention, alert = error.
public enum HTTone: Equatable {
    case normal, amber, alert
    public var color: Color {
        switch self {
        case .normal: HT.C.ink
        case .amber: HT.C.amber
        case .alert: HT.C.alert
        }
    }
}

/// `LABEL // value` — text only, no dots or pills.
public struct StatusText: View {
    let label: String, value: String, tone: HTTone
    public init(label: String, value: String, tone: HTTone = .normal) { self.label = label; self.value = value; self.tone = tone }
    public var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(HT.C.ink3)
            Text("//").foregroundStyle(HT.C.ink3)
            Text(value).foregroundStyle(tone.color)
        }
        .ht(.labelSmall).lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label).accessibilityValue(value)
    }
}

#Preview {
    VStack(alignment: .leading) {
        StatusText(label: "Conn", value: "shop")
        StatusText(label: "Pending", value: "2,214", tone: .amber)
        StatusText(label: "Error", value: "timeout", tone: .alert)
    }.padding().background(HT.C.paper)
}
