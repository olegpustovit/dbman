import DBCore
import Halftone
import SwiftUI

/// States 01 for a connection: silent for 400 ms, then the route (this Mac → SSH hop → server → database), one line per stage
/// with its own timing, a plain-language hint when a stage is slow, and CANCEL // ⌘.
struct ConnectingView: View {
    let ws: WorkspaceModel

    private var p: ConnectionProfile { ws.profile }
    private var steps: [HTStep] { ws.connectSteps }
    private var active: HTStep? { steps.first { $0.state.isActive } }
    private var doneCount: Int { steps.filter { if case .done = $0.state { return true } else { return false } }.count }

    var body: some View {
        HTFrame(title: "CONNECTING", tail: p.name, accessory: { ElapsedText(since: ws.connectStarted) }) {
            LateReveal {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    route
                    HTStepList(steps)
                        .padding(.horizontal, 10)
                        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
                    HStack {
                        Spacer(minLength: 8)
                        Button("Cancel  ⌘.") { ws.cancelConnect() }.buttonStyle(.htOutline).keyboardShortcut(".", modifiers: .command)
                    }
                    .padding(.top, -6)
                    slowHint // last: the panel is top-aligned, so the hint appearing moves nothing above it
                }
                .padding(20)
                .frame(maxWidth: 600)
            }
            // pinned near the top, not centred: a wrapping detail or the slow hint never moves what is already on screen
            .padding(.top, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                CapsLabel("Elapsed").foregroundStyle(HT.C.ink3)
                ElapsedText(since: ws.connectStarted, font: .readoutL, tint: HT.C.ink)
            }
            VStack(alignment: .leading, spacing: 2) {
                CapsLabel("Stages").foregroundStyle(HT.C.ink3)
                Text("\(doneCount)/\(steps.count)").ht(.readoutL).foregroundStyle(HT.C.ink).contentTransition(.numericText()).animation(HT.Motion.roll, value: doneCount)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                StatusText(label: "Engine", value: p.engine.displayName.uppercased())
                StatusText(label: "Env", value: p.environment.rawValue.uppercased(), tone: p.environment == .production ? .amber : .normal)
                if let a = active { StatusText(label: "Now", value: a.title.uppercased(), tone: .normal).foregroundStyle(HT.C.accent) }
            }
        }
    }

    // MARK: route

    private struct Hop: Identifiable { let id: Int; let label: String; let value: String }

    private var hops: [Hop] {
        var h = [Hop(id: 0, label: "FROM", value: "this Mac")]
        if let t = p.ssh { h.append(Hop(id: h.count, label: "SSH", value: t.display)) }
        if p.engine == .sqlite {
            h.append(Hop(id: h.count, label: "FILE", value: ((p.filePath ?? "") as NSString).lastPathComponent))
        } else {
            h.append(Hop(id: h.count, label: p.ssh == nil ? "SERVER" : "SERVER · ON SSH HOST", value: "\(p.host):\(p.port)"))
            h.append(Hop(id: h.count, label: "DATABASE", value: p.database.isEmpty ? "default" : p.database))
        }
        return h
    }

    /// The hop the current stage is working towards; earlier hops are reached.
    private var focusHop: Int {
        let last = hops.count - 1
        switch active?.id {
        case ConnectStage.tunnel.rawValue: return 1
        case ConnectStage.handshake.rawValue: return p.ssh == nil ? 1 : 2
        case nil: return doneCount == steps.count ? last : 0
        default: return last
        }
    }

    private var route: some View {
        let f = focusHop
        return HStack(alignment: .top, spacing: 8) { hopViews(f, arrows: true) }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
        .accessibilityElement(children: .combine).accessibilityLabel("Route")
    }

    @ViewBuilder private func hopViews(_ f: Int, arrows: Bool) -> some View {
        ForEach(hops) { h in
            if arrows && h.id > 0 { Text("→").ht(.data).foregroundStyle(h.id <= f ? HT.C.ink2 : HT.C.fill30).padding(.top, 13) }
            VStack(alignment: .leading, spacing: 2) {
                CapsLabel(h.label).foregroundStyle(h.id == f ? HT.C.accent : HT.C.ink3)
                Text(h.value).ht(.dataSmall).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(h.id == f ? HT.C.accent : h.id < f ? HT.C.ink : HT.C.ink3)
                    .help(h.value)
            }
            .layoutPriority(h.label == "SSH" ? 0 : 1) // the long SSH host truncates first
        }
    }

    // MARK: slow hint

    /// After 6 s on one stage, say what usually causes the wait there.
    private var slowHint: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let a = active, case .active(let since) = a.state, ctx.date.timeIntervalSince(since) > 6 {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    CapsLabel("Slow").foregroundStyle(HT.C.amber)
                    Text(hint(a.id)).ht(.bodySmall).foregroundStyle(HT.C.ink2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.amber, lineWidth: 1))
                .transition(.opacity)
            }
        }
    }

    private func hint(_ id: String) -> String {
        switch id {
        case ConnectStage.tunnel.rawValue:
            return "ssh has not finished logging in to \(p.ssh?.host ?? "the SSH host"). Check the host is reachable (VPN / Tailscale up?). DBMan runs ssh without prompts, so your key must be in the agent or ~/.ssh/config."
        case ConnectStage.handshake.rawValue:
            return p.ssh != nil
                ? "The tunnel is up, but nothing answers at \(p.host):\(p.port) on the SSH host. Is the database (or its container) running and published on that port?"
                : "No answer from \(p.host):\(p.port) yet. A firewall, a wrong port or a sleeping server usually looks like this."
        case "schema":
            return "Reading every table, column and key once. Large catalogues and remote links take a while; the window opens as soon as this finishes."
        default:
            return "Building the overview for this connection."
        }
    }
}
