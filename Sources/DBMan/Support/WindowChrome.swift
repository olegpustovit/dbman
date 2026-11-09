import AppKit
import Halftone
import SwiftUI

/// Halftone window chrome: the titlebar is transparent and the window's own backdrop bleeds up under the traffic lights;
/// the system title is hidden and drawn here instead, centred, in caps (macOS 26 left-aligns a merged title).
struct WindowChrome: ViewModifier {
    let title: String
    var subtitle: String? = nil
    static let band: CGFloat = 28

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content.padding(.top, Self.band)
            HStack(spacing: 6) {
                Text(title).ht(.label).foregroundStyle(HT.C.ink)
                if let subtitle, !subtitle.isEmpty { HTDivider(); Text(subtitle).ht(.label).foregroundStyle(HT.C.ink3) }
            }
            .lineLimit(1).padding(.horizontal, 90) // clear of the traffic lights on either side
            .frame(maxWidth: .infinity).frame(height: Self.band)
            .background(HT.C.paper) // one surface with the top strip below it: no line under the title
            .allowsHitTesting(false) // clicks fall through to the titlebar: drag and double-click to zoom keep working
            .accessibilityHidden(true)
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .title) // SwiftUI re-applies the system title on navigation; remove it at the source
        .background(WindowConfigurator(title: title))
    }
}

extension View {
    func windowChrome(_ title: String, subtitle: String? = nil) -> some View { modifier(WindowChrome(title: title, subtitle: subtitle)) }
}

/// Finds the hosting NSWindow and sets the transparent, full-size-content titlebar once (and keeps the real title for Mission Control / the Window menu).
private struct WindowConfigurator: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { configure(v.window) } }
    private func configure(_ w: NSWindow?) {
        guard let w else { return }
        if !w.styleMask.contains(.fullSizeContentView) { w.styleMask.insert(.fullSizeContentView) }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = title
        w.isMovableByWindowBackground = false
    }
}
