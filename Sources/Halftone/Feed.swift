import SwiftUI

/// Icon + two-line caps/sentence + muted time.
public struct ActivityItem: View {
    let icon: String, title: String, detail: String, time: String, tone: HTTone
    public init(icon: String, title: String, detail: String, time: String, tone: HTTone = .normal) {
        self.icon = icon; self.title = title; self.detail = detail; self.time = time; self.tone = tone
    }
    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tone.color)
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(tone == .normal ? HT.C.line : tone.color, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).ht(.labelSmall).foregroundStyle(tone.color)
                Text(detail).ht(.bodySmall).foregroundStyle(HT.C.ink2).lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(time).ht(.dataSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)").accessibilityValue(time)
    }
}

/// Large outlined choice tile; selected = inverted.
public struct OptionTile: View {
    let title: String, subtitle: String, isSelected: Bool, action: () -> Void
    public init(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void = {}) {
        self.title = title; self.subtitle = subtitle; self.isSelected = isSelected; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).ht(.label)
                Text(subtitle).ht(.bodySmall).opacity(0.7)
            }
            .foregroundStyle(isSelected ? HT.C.paper : HT.C.ink)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading).padding(10)
            .background(isSelected ? HT.C.ink : .clear, in: RoundedRectangle(cornerRadius: HT.M.radius))
            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(isSelected ? HT.C.ink : HT.C.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityHint(subtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    VStack(spacing: 8) {
        ActivityItem(icon: "bolt", title: "Query ran", detail: "SELECT * FROM orders", time: "30_min_ago")
        ActivityItem(icon: "exclamationmark.triangle", title: "Slow", detail: "Seq scan on orders", time: "2_min_ago", tone: .amber)
        HStack { OptionTile(title: "Postgres", subtitle: "TCP · 5432", isSelected: true); OptionTile(title: "SQLite", subtitle: "File", isSelected: false) }
    }.padding().frame(width: 320).background(HT.C.paper)
}
