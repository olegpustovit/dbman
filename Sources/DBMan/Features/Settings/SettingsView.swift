import Halftone
import SwiftUI

/// Settings scene: app-wide defaults, persisted in the DBMan store (via AppModel).
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var app = appModel
        return VStack(spacing: HT.M.seam) {
            HTFrame(title: "APPEARANCE", tail: "SYSTEM") {
                note("Follows the macOS appearance (Light or Dark). Change it in System Settings.")
                    .padding(10)
            }
            HTFrame(title: "RESULTS", tail: "PAGE SIZE") {
                HStack(spacing: 14) {
                    Readout(value: app.pageSize.formatted(), label: "ROWS PER PAGE", size: .s)
                    Spacer(minLength: 0)
                    Stepper("Rows per page", value: $app.pageSize, in: 100...5000, step: 100).labelsHidden()
                }
                .padding(10)
            }
            HTFrame(title: "DATES", tail: "DEFAULT") {
                HStack {
                    HTToggleChip("RELATIVE DATES", isOn: $app.relativeDates)
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
