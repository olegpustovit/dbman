import SwiftUI

/// Boxed caps button. `.htOutline`, `.htPrimary` (inverted), `.htDestructive`.
public struct HTButtonStyle: ButtonStyle {
    public enum Kind { case outline, primary, destructive }
    let kind: Kind
    @Environment(\.isEnabled) private var enabled
    public func makeBody(configuration: Configuration) -> some View {
        let tint = kind == .destructive ? HT.C.alert : HT.C.ink
        let filled = kind == .primary
        configuration.label
            .font(.system(size: 10.5, weight: .semibold).width(.condensed)).tracking(0.9).textCase(.uppercase)
            .foregroundStyle(filled ? HT.C.paper : tint)
            .padding(.horizontal, 8).frame(height: HT.M.control)
            .background(filled ? tint : (configuration.isPressed ? HT.C.fill12 : .clear), in: RoundedRectangle(cornerRadius: HT.M.radius))
            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(tint, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed && filled ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
extension ButtonStyle where Self == HTButtonStyle {
    public static var htOutline: HTButtonStyle { .init(kind: .outline) }
    public static var htPrimary: HTButtonStyle { .init(kind: .primary) }
    public static var htDestructive: HTButtonStyle { .init(kind: .destructive) }
}

/// Top-strip nav button: stroke icon + caps label; active = solid ink.
public struct HTNavButton: View {
    let title: String, systemImage: String, isActive: Bool, action: () -> Void
    public init(_ title: String, systemImage: String, isActive: Bool, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.isActive = isActive; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .regular))
                Text(title)
            }
            .ht(.labelSmall)
            .foregroundStyle(isActive ? HT.C.paper : HT.C.ink)
            .padding(.horizontal, 8).frame(height: 22)
            .background(isActive ? HT.C.ink : .clear, in: RoundedRectangle(cornerRadius: HT.M.radius))
            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.ink, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Boxed segmented control, selection inverted.
public struct HTSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, title: String)]
    public init(selection: Binding<T>, options: [(value: T, title: String)]) { _selection = selection; self.options = options }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button { withAnimation(HT.Motion.snap) { selection = options[i].value } } label: {
                    Text(options[i].title).ht(.labelSmall)
                        .foregroundStyle(on ? HT.C.paper : HT.C.ink)
                        .padding(.horizontal, 8).frame(height: HT.M.control)
                        .background(on ? HT.C.ink : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HT.M.radius))
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.ink, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Search box with optional shortcut hint (e.g. "⌘F").
public struct HTSearchField: View {
    @Binding var text: String
    let prompt: String, shortcut: String?
    public init(text: Binding<String>, prompt: String = "Search", shortcut: String? = nil) {
        _text = text; self.prompt = prompt; self.shortcut = shortcut
    }
    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(HT.C.ink3).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain).ht(.bodySmall)
            if let shortcut { Text(shortcut).ht(.labelSmall).foregroundStyle(HT.C.ink3).accessibilityHidden(true) }
        }
        .padding(.horizontal, 6).frame(height: 22)
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
        .accessibilityLabel(prompt)
    }
}

/// Boxed on/off chip; on = inverted.
public struct HTToggleChip: View {
    let title: String
    @Binding var isOn: Bool
    public init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    public var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(ChipStyle())
    }
    private struct ChipStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button { configuration.isOn.toggle() } label: {
                configuration.label.ht(.labelSmall)
                    .foregroundStyle(configuration.isOn ? HT.C.paper : HT.C.ink)
                    .padding(.horizontal, 7).frame(height: HT.M.control)
                    .background(configuration.isOn ? HT.C.ink : .clear, in: RoundedRectangle(cornerRadius: HT.M.radius))
                    .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(configuration.isOn ? HT.C.ink : HT.C.line, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        }
    }
}

#Preview {
    struct P: View {
        @State var seg = 1; @State var q = ""; @State var on = true
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Cancel") {}.buttonStyle(.htOutline)
                    Button("Run") {}.buttonStyle(.htPrimary)
                    Button("Drop") {}.buttonStyle(.htDestructive)
                }
                HStack { HTNavButton("Query", systemImage: "terminal", isActive: true) {}; HTNavButton("Tables", systemImage: "tablecells", isActive: false) {} }
                HTSegmented(selection: $seg, options: [(0, "Rows"), (1, "Cols"), (2, "DDL")])
                HTSearchField(text: $q, prompt: "Filter", shortcut: "⌘F").frame(width: 180)
                HTToggleChip("Live", isOn: $on)
            }.padding().background(HT.C.paper)
        }
    }
    return P()
}
