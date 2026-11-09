import Halftone
import SwiftUI

/// Settings scene: app-wide defaults, persisted with @AppStorage.
struct SettingsView: View {
    @AppStorage("pageSize") private var pageSize = 500
    @AppStorage("relativeDates") private var relativeDates = false

    var body: some View {
        VStack(spacing: HT.M.gap) {
            HTFrame(title: "APPEARANCE", tail: "SYSTEM") {
                note("Follows the macOS appearance (Light or Dark). Change it in System Settings.")
                    .padding(10)
            }
            HTFrame(title: "RESULTS", tail: "PAGE SIZE") {
                HStack(spacing: 14) {
                    Readout(value: pageSize.formatted(), label: "ROWS PER PAGE", size: .s)
                    Spacer(minLength: 0)
                    Stepper("Rows per page", value: $pageSize, in: 100...5000, step: 100).labelsHidden()
                }
                .padding(10)
            }
            HTFrame(title: "DATES", tail: "DEFAULT") {
                HStack {
                    HTToggleChip("RELATIVE DATES", isOn: $relativeDates)
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
            HTFrame(title: "SAFETY", tail: "PRODUCTION") {
                VStack(alignment: .leading, spacing: 6) {
                    HTToggleChip("CONFIRM PRODUCTION WRITES", isOn: .constant(true))
                        .disabled(true)
                        .opacity(0.45)
                    note("Always on. Writes to production connections are staged and need review before commit.")
                }
                .padding(10)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(HT.M.windowPadding)
        .frame(width: 480)
        .background(DotGridBackground())
    }

    private func note(_ text: String) -> some View {
        Text(text).ht(.bodySmall).foregroundStyle(HT.C.ink2).frame(maxWidth: .infinity, alignment: .leading)
    }
}
