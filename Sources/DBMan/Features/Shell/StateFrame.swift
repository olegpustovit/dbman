import DBCore
import Halftone
import SwiftUI

/// Centred message inside an HTFrame; when running, the dot spinner and elapsed time appear only after 400 ms (Doherty threshold).
struct StateFrame: View {
    let title: String
    let tail: String?
    let message: String
    var running: Bool = false
    @State private var showSpinner = false
    @State private var since = Date()

    var body: some View {
        HTFrame(title: title, tail: tail) {
            VStack(spacing: 10) {
                if running && showSpinner { DotSpinner().transition(.opacity) }
                Text(message).ht(.label).foregroundStyle(HT.C.ink3).multilineTextAlignment(.center)
                if running && showSpinner { ElapsedText(since: since, font: .label, tint: HT.C.ink2).transition(.opacity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: running) {
            showSpinner = false
            since = Date()
            guard running else { return }
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(HT.Motion.enter) { showSpinner = true }
        }
    }
}
