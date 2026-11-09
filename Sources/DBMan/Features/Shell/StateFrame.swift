import DBCore
import Halftone
import SwiftUI

/// Centred message inside an HTFrame; the spinner appears only after 400 ms (Doherty threshold).
struct StateFrame: View {
    let title: String
    let tail: String?
    let message: String
    var running: Bool = false
    @State private var showSpinner = false

    var body: some View {
        HTFrame(title: title, tail: tail) {
            VStack(spacing: 10) {
                if running && showSpinner { ProgressView().controlSize(.small).transition(.opacity) }
                Text(message).ht(.label).foregroundStyle(HT.C.ink3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: running) {
            showSpinner = false
            guard running else { return }
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(HT.Motion.enter) { showSpinner = true }
        }
    }
}
