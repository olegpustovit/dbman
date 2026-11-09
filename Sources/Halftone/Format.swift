import Foundation

/// Locale-aware number formatting shared by every screen, so "2,4K" and "168.0K" never mix.
public enum HTFormat {
    /// 2400 → "2.4K" / "2,4K" (system compact notation), 35 510 000 → "35.5M".
    public static func compact(_ n: Int64) -> String { n.formatted(.number.notation(.compactName)) }
    /// 289984 → "289,984" in the user's locale.
    public static func grouped(_ n: Int64) -> String { n.formatted(.number.grouping(.automatic)) }
}
