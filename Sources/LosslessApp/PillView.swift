import LosslessEngine
import SwiftUI

struct PillView: View {
    let phase: PipelinePhase
    let onOpen: () -> Void
    var onFixBlockers: () -> Void = {}
    var onRetry: () -> Void = {}
    var onCopyWithheld: (() -> Void)?
    var onDismiss: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: PhasePresentation { phase.presentation }

    var body: some View {
        HStack(spacing: 10) {
            if presentation.showsMeter {
                Meter(level: level)
            } else if !presentation.symbol.isEmpty {
                Image(systemName: presentation.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(presentation.emphasised ? Ink.attention : Ink.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14)
            }

            Text(presentation.label)
                .font(Kind.caption)
                .foregroundStyle(presentation.emphasised ? Ink.primary : Ink.secondary)
                .monospacedDigit()
                .lineLimit(1)

            if case .blocked = phase {
                Button("Fix", action: onFixBlockers)
                    .buttonStyle(.plain)
                    .font(Kind.caption)
                    .foregroundStyle(Ink.attention)
            }

            if case .failed(let failure) = phase, failure.canRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .font(Kind.caption)
                    .foregroundStyle(Ink.attention)
            }

            if let onCopyWithheld, case .delivered(let summary) = phase, summary.offersCopy {
                Button("Copy", action: onCopyWithheld)
                    .buttonStyle(.plain)
                    .font(Kind.caption)
                    .foregroundStyle(Ink.attention)
            }

            if presentation.offersReview {
                Button("Review", action: onOpen)
                    .buttonStyle(.plain)
                    .font(Kind.caption)
                    .foregroundStyle(Ink.attention)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.pillHeight)
        .glassCapsule()
        .onTapGesture { if phase.visibility == .persistent { onDismiss() } }
        .help(phase.visibility == .persistent ? "Click to dismiss" : "")
        .animation(reduceMotion ? nil : Motion.standard, value: presentation)
        .fixedSize()
    }

    private var level: Double {
        if case .listening(let level) = phase { return level }
        if case .acting(let banner) = phase { return banner.level }
        return 0
    }
}

private struct Meter: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bars = 5

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(Ink.primary.opacity(opacity(index)))
                    .frame(width: 2.5, height: height(index))
            }
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : Motion.meter, value: level)
    }

    private func amplitude(_ index: Int) -> Double {
        let centre = Double(Self.bars - 1) / 2
        let falloff = 1 - abs(Double(index) - centre) / (centre + 1)
        return level * falloff
    }

    private func height(_ index: Int) -> CGFloat { 3 + 11 * amplitude(index) }
    private func opacity(_ index: Int) -> Double { 0.25 + 0.6 * amplitude(index) }
}
