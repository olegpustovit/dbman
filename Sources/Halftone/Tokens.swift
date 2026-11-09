import AppKit
import SwiftUI

/// Halftone 0.7 — "Inverted FUI". White paper, monochrome ink, one cobalt signal.
/// Colour means something: accent = live / now / selected, amber = attention, alert = error.
public enum HT {}

extension NSColor {
    public convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    /// Resolves per appearance at draw time.
    public static func ht(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in
            let m = ap.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            return (m == .darkAqua || m == .vibrantDark) ? dark : light
        }
    }
}

extension HT {
    /// AppKit colours (grid, editor). Mirror of `HT.Color`.
    public enum NS {
        public static let backdrop = NSColor.ht(.init(hex: 0xF3F3F1), .init(hex: 0x050506))
        public static let paper    = NSColor.ht(.init(hex: 0xFFFFFF), .init(hex: 0x0B0B0C))
        public static let sunken   = NSColor.ht(.init(hex: 0xF6F6F4), .init(hex: 0x121214))
        public static let ink      = NSColor.ht(.init(hex: 0x0B0B0C), .init(hex: 0xF2F2F0))
        public static let ink2     = NSColor.ht(.init(hex: 0x3C3C40), .init(hex: 0xC4C4C8))
        public static let ink3     = NSColor.ht(.init(hex: 0x6A6A70), .init(hex: 0x8E8E94))
        public static let line     = NSColor.ht(.init(hex: 0x0B0B0C, alpha: 0.14), .init(hex: 0xFFFFFF, alpha: 0.14))
        public static let fill12   = NSColor.ht(.init(hex: 0x0B0B0C, alpha: 0.08), .init(hex: 0xFFFFFF, alpha: 0.08))
        public static let fill30   = NSColor.ht(.init(hex: 0x0B0B0C, alpha: 0.22), .init(hex: 0xFFFFFF, alpha: 0.22))
        public static let accent   = NSColor.ht(.init(hex: 0x2F2FE4), .init(hex: 0x8A8AFF))
        public static let accentSoft = NSColor.ht(.init(hex: 0x2F2FE4, alpha: 0.08), .init(hex: 0x8A8AFF, alpha: 0.12))
        public static let amber    = NSColor.ht(.init(hex: 0xA86400), .init(hex: 0xE0A84E))
        public static let alert    = NSColor.ht(.init(hex: 0xD21F1A), .init(hex: 0xFF6A5E))
        public static let dotGrid  = NSColor.ht(.init(hex: 0x0B0B0C, alpha: 0.06), .init(hex: 0xFFFFFF, alpha: 0.06))
    }

    public enum C {
        public static let backdrop = Color(nsColor: NS.backdrop)
        public static let paper = Color(nsColor: NS.paper)
        public static let sunken = Color(nsColor: NS.sunken)
        public static let ink = Color(nsColor: NS.ink)
        public static let ink2 = Color(nsColor: NS.ink2)
        public static let ink3 = Color(nsColor: NS.ink3)
        public static let line = Color(nsColor: NS.line)
        public static let fill12 = Color(nsColor: NS.fill12)
        public static let fill30 = Color(nsColor: NS.fill30)
        public static let accent = Color(nsColor: NS.accent)
        public static let accentSoft = Color(nsColor: NS.accentSoft)
        public static let amber = Color(nsColor: NS.amber)
        public static let alert = Color(nsColor: NS.alert)
        public static let dotGrid = Color(nsColor: NS.dotGrid)
    }

    /// Density metrics (points).
    public enum M {
        public static let windowPadding: CGFloat = 6
        public static let gap: CGFloat = 4
        public static let radius: CGFloat = 3
        public static let topStrip: CGFloat = 30
        public static let rail: CGFloat = 28
        public static let statusStrip: CGFloat = 20
        public static let sidebar: CGFloat = 220
        public static let inspector: CGFloat = 300
        public static let row: CGFloat = 24
        public static let frameHeader: CGFloat = 26
        public static let control: CGFloat = 20
    }

    /// Motion tokens; Reduce Motion collapses them to short fades.
    public enum Motion {
        @MainActor public static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        @MainActor public static var snap: Animation { reduce ? .easeOut(duration: 0.12) : .snappy(duration: 0.18) }
        @MainActor public static var glide: Animation { reduce ? .easeOut(duration: 0.12) : .smooth(duration: 0.22) }
        @MainActor public static var enter: Animation { reduce ? .easeOut(duration: 0.12) : .snappy(duration: 0.20) }
        @MainActor public static var roll: Animation { reduce ? .easeOut(duration: 0.12) : .smooth(duration: 0.30) }
    }
}
