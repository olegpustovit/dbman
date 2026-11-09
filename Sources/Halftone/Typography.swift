import SwiftUI

/// The three voices of v7:
/// - UI text: SF Pro 12/13
/// - LABEL: SF Pro condensed caps, tracked — the FUI voice, with `//` separators
/// - READOUT: huge light numerals; DATA/SQL: SF Mono 12
public enum HTFont {
    case body, bodySmall, strong
    case label, labelSmall
    case readoutS, readoutM, readoutL, readoutXL
    case data, dataSmall, code

    public var font: Font {
        switch self {
        case .body: .system(size: 13)
        case .bodySmall: .system(size: 12)
        case .strong: .system(size: 13, weight: .semibold)
        case .label: .system(size: 11, weight: .semibold).width(.condensed)
        case .labelSmall: .system(size: 10, weight: .semibold).width(.condensed)
        case .readoutS: .system(size: 22, weight: .light).monospacedDigit()
        case .readoutM: .system(size: 30, weight: .light).monospacedDigit()
        case .readoutL: .system(size: 42, weight: .light).monospacedDigit()
        case .readoutXL: .system(size: 56, weight: .thin).monospacedDigit()
        case .data: .system(size: 12, design: .monospaced)
        case .dataSmall: .system(size: 11, design: .monospaced)
        case .code: .system(size: 12.5, design: .monospaced)
        }
    }
    var tracking: CGFloat {
        switch self {
        case .label, .labelSmall: 0.9
        case .readoutM: -0.9
        case .readoutL: -1.3
        case .readoutXL: -1.8
        default: 0
        }
    }
    var uppercase: Bool { self == .label || self == .labelSmall }
}

struct HTFontModifier: ViewModifier {
    let f: HTFont
    func body(content: Content) -> some View {
        content.font(f.font).tracking(f.tracking).textCase(f.uppercase ? .uppercase : nil)
    }
}

extension View {
    public func ht(_ f: HTFont) -> some View { modifier(HTFontModifier(f: f)) }
}

/// `RECORDS // LIVE` — the label voice with an optional muted tail.
public struct CapsLabel: View {
    let title: String
    let tail: String?
    public init(_ title: String, _ tail: String? = nil) { self.title = title; self.tail = tail }
    public var body: some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(HT.C.ink)
            if let tail {
                Text("//").foregroundStyle(HT.C.ink3)
                Text(tail).foregroundStyle(HT.C.ink3)
            }
        }
        .ht(.label)
        .lineLimit(1)
    }
}
