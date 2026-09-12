import LosslessEngine
import LosslessKit
import SwiftUI

struct InspectorView: View {
    let graph: RepairGraph?
    let compiled: CompiledTranscript?
    let destination: String?
    let onCopyAlternative: (String) -> Void
    var developerMode = false

    var body: some View {
        if let graph {
            ScrollView { content(graph) }
        } else {
            Text("Hold \(HotkeyTap.triggerLabel) and speak.")
                .font(Kind.body)
                .foregroundStyle(Ink.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func content(_ graph: RepairGraph) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            Text(verdict(graph))
                .font(Kind.display.weight(.semibold))
                .foregroundStyle(
                    Transcript(graph, compiled: compiled, cleanupDegraded: false).problems
                        .isEmpty ? Ink.primary : Ink.attention)

            section(destination.map { "What landed in \($0)" } ?? "What landed") {
                Text(compiled?.text ?? graph.clean)
                    .font(Kind.display)
                    .lineSpacing(6)
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
            }

            if !graph.outline.isEmpty {
                section("Changes") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(graph.outline) { node in
                            EventRow(
                                node: node, developerMode: developerMode,
                                onCopyAlternative: onCopyAlternative)
                            if node.id != graph.outline.last?.id {
                                Divider().foregroundStyle(Ink.faint.opacity(0.4))
                            }
                        }
                    }
                }
            }

            section("What you said") {
                Text(graph.ribbonText)
                    .font(Kind.display)
                    .lineSpacing(6)
                    .textSelection(.enabled)
            }
        }
        .padding(Metrics.gutter * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verdict(_ graph: RepairGraph) -> String {
        Transcript(graph, compiled: compiled, cleanupDegraded: false).inspectorVerdict
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).sectionTitle()
            content()
        }
    }
}

private struct EventRow: View {
    let node: RepairOutlineNode
    let developerMode: Bool
    let onCopyAlternative: (String) -> Void

    @State private var isHovering = false

    private var event: RepairEvent { node.event }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(event))
                        .font(Kind.body)
                        .monospacedDigit()
                    if developerMode {
                        Text(developerDetail)
                            .font(Kind.caption.monospaced())
                            .foregroundStyle(Ink.faint)
                            .textSelection(.enabled)
                    }
                }

                Spacer(minLength: 8)

                if event.resolution.isProblem, let after = event.after {
                    Button("Copy \"\(after)\"") { onCopyAlternative(after) }
                        .glassButton()
                        .controlSize(.small)
                        .font(Kind.caption)
                        .opacity(isHovering ? 1 : 0)
                }
            }

            ForEach(node.children) { child in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(headline(child))
                        .font(Kind.caption)
                        .foregroundStyle(Ink.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 11)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    private var developerDetail: String {
        let spans = event.evidence.rawSpans.map { "\($0.start)..<\($0.end)" }.joined(separator: " ")
        return "\(event.grade.rawValue)  \(event.signalSummary)  raw \(spans)"
    }

    private func headline(_ event: RepairEvent) -> AttributedString {
        guard let before = event.before, let after = event.after else {
            var only = AttributedString(event.after ?? event.before ?? "")
            only.foregroundColor = Ink.secondary
            return only
        }
        guard event.kind.showsTransition else {
            var subject = AttributedString("\(before)  ")
            subject.foregroundColor = Ink.faint
            var reason = AttributedString(after)
            reason.foregroundColor = Ink.secondary
            return subject + reason
        }
        var old = AttributedString(before)
        old.foregroundColor = Ink.secondary
        old.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Ink.faint)
        var arrow = AttributedString("  \u{2192}  ")
        arrow.foregroundColor = Ink.faint
        var new = AttributedString(after)
        new.foregroundColor = Ink.primary
        new.font = Kind.body.weight(.semibold)
        return old + arrow + new
    }
}
