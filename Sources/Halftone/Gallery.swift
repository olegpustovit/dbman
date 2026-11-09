import SwiftUI

/// Every component, for previews and a debug window.
public struct HalftoneGallery: View {
    @State private var rail = 0
    @State private var seg = 0
    @State private var q = ""
    @State private var chip = true
    @State private var tile = 0
    public init() {}
    public var body: some View {
        HStack(spacing: HT.M.gap) {
            NumberRail(items: [("01", "Overview"), ("02", "Tables"), ("03", "Query"), ("04", "Activity")], selection: $rail)
            ScrollView {
                VStack(spacing: HT.M.gap) {
                    HStack(spacing: HT.M.gap) {
                        HTNavButton("Overview", systemImage: "square.grid.2x2", isActive: rail == 0) { rail = 0 }
                        HTNavButton("Query", systemImage: "terminal", isActive: rail == 2) { rail = 2 }
                        Spacer()
                        StatusText(label: "Session", value: "shop")
                        StatusText(label: "Pending", value: "2,214", tone: .amber)
                        StatusText(label: "Error", value: "timeout", tone: .alert)
                    }
                    HStack(alignment: .top, spacing: HT.M.gap) {
                        HTFrame(title: "Records", tail: "Live", accessory: { Button("Export") {}.buttonStyle(.htOutline) }) {
                            HStack(spacing: 24) {
                                Readout(value: "290,198", label: "Rows", size: .l)
                                Readout(value: "48,000", label: "Orders", tail: "Total", size: .m)
                            }.padding(8)
                        }
                        HTFrame(title: "Throughput", tail: "Last_14_days") {
                            LineChart(series: [[3, 5, 4, 8, 6, 9, 7, 8], [2, 3, 3, 4, 5, 4, 6, 5]], styles: [.solid, .ink30], highlightIndex: 6).frame(height: 110).padding(8)
                        }
                    }
                    HStack(alignment: .top, spacing: HT.M.gap) {
                        HTFrame(title: "Spectrum") {
                            VStack(spacing: 8) {
                                BarSpectrum(values: (0..<40).map { Double(($0 * 7) % 13 + 2) }, highlight: 20).frame(height: 50)
                                SegmentedMeter(value: 0.62, tint: .amber)
                                Sparkline(values: [1, 3, 2, 5, 4, 6])
                            }.padding(8)
                        }
                        HTFrame(title: "Density") {
                            Halftone(levels: (0..<8).map { r in (0..<24).map { c in UInt8((r * c) % 5) } }, highlight: (3, 10)).frame(height: 90).padding(8)
                        }
                        HTFrame(title: "Profile") {
                            RadarChart(values: [0.8, 0.5, 0.7, 0.4, 0.9], labels: ["Read", "Write", "Idx", "Lock", "Net"]).frame(height: 130)
                        }
                    }
                    HTFrame(title: "Controls") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button("Cancel") {}.buttonStyle(.htOutline)
                                Button("Run") {}.buttonStyle(.htPrimary)
                                Button("Drop") {}.buttonStyle(.htDestructive)
                                HTSegmented(selection: $seg, options: [(0, "Rows"), (1, "Cols"), (2, "DDL")])
                                HTToggleChip("Live", isOn: $chip)
                                HTSearchField(text: $q, prompt: "Filter", shortcut: "⌘F").frame(width: 160)
                            }
                            ActivityItem(icon: "bolt", title: "Query ran", detail: "SELECT * FROM orders", time: "30_min_ago")
                            ActivityItem(icon: "exclamationmark.triangle", title: "Slow query", detail: "Seq scan on orders", time: "2_min_ago", tone: .amber)
                            HStack {
                                OptionTile(title: "Postgres", subtitle: "TCP · 5432", isSelected: tile == 0) { tile = 0 }
                                OptionTile(title: "SQLite", subtitle: "File", isSelected: tile == 1) { tile = 1 }
                            }
                        }.padding(8)
                    }
                }.padding(HT.M.windowPadding)
            }
        }
        .padding(HT.M.windowPadding)
        .background(DotGridBackground())
    }
}

#Preview { HalftoneGallery().frame(width: 820, height: 760) }
