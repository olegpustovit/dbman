import AppKit
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
/// A clickable card: a choice in a picker (`isSelected`), or an action (`arrow: true` adds →).
/// Solid paper, a visible border, ink border + tint on hover, and a press state, so it reads as a button on the dot grid.
public struct OptionTile: View {
    let title: String, subtitle: String, isSelected: Bool, arrow: Bool, action: () -> Void
    public init(title: String, subtitle: String, isSelected: Bool, arrow: Bool = false, action: @escaping () -> Void = {}) {
        self.title = title; self.subtitle = subtitle; self.isSelected = isSelected; self.arrow = arrow; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).ht(.label)
                    Text(subtitle).ht(.bodySmall).opacity(0.7)
                }
                Spacer(minLength: 0)
                if arrow { Text("→").font(.system(size: 15, weight: .medium)) }
            }
        }
        .buttonStyle(TileStyle(isSelected: isSelected, arrow: arrow))
        .accessibilityLabel(title).accessibilityHint(subtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TileStyle: ButtonStyle {
    let isSelected: Bool, arrow: Bool
    func makeBody(configuration: Configuration) -> some View { TileBody(configuration: configuration, isSelected: isSelected, arrow: arrow) }

    struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool, arrow: Bool
        @State private var hover = false
        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle(isSelected ? HT.C.paper : HT.C.ink)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading).padding(10)
                .background(isSelected ? HT.C.ink : (hover || pressed ? HT.C.accentSoft : HT.C.paper), in: RoundedRectangle(cornerRadius: HT.M.radius))
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(isSelected || hover ? HT.C.ink : HT.C.ink.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(isSelected || pressed ? 0 : 0.06), radius: 0, x: 0, y: hover ? 2 : 1)
                .offset(y: pressed ? 1 : 0)
                .contentShape(Rectangle())
                .onHover { h in hover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        ActivityItem(icon: "bolt", title: "Query ran", detail: "SELECT * FROM orders", time: "30_min_ago")
        ActivityItem(icon: "exclamationmark.triangle", title: "Slow", detail: "Seq scan on orders", time: "2_min_ago", tone: .amber)
        HStack { OptionTile(title: "Postgres", subtitle: "TCP · 5432", isSelected: true); OptionTile(title: "SQLite", subtitle: "File", isSelected: false) }
    }.padding().frame(width: 320).background(HT.C.paper)
}
