import LosslessEngine
import SwiftUI

enum Ink {
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let attention = Color(nsColor: .systemOrange)
}

enum Kind {
    static let caption = Font.system(size: 11, weight: .medium)
    static let body = Font.system(size: 13, weight: .regular)
    static let display = Font.system(size: 16, weight: .regular)
}

extension Text {
    func sectionTitle() -> some View {
        self.font(Kind.caption).foregroundStyle(Ink.faint)
    }
}

enum Motion {
    static let standard = Animation.smooth(duration: 0.32)
    static let meter = Animation.linear(duration: 0.08)
}

enum Metrics {
    static let pillHeight: CGFloat = 38
    static let pillBottomInset: CGFloat = 140
    static let inspectorCorner: CGFloat = 20
    static let gutter: CGFloat = 18
}

extension View {
    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

extension RepairGraph {
    var ribbonText: AttributedString {
        ribbon.reduce(into: AttributedString()) { result, run in
            var piece = AttributedString(run.text)
            switch run.style {
            case .normal:
                piece.foregroundColor = Ink.secondary
            case .removed:
                piece.foregroundColor = Ink.faint
            case .replaced:
                piece.foregroundColor = Ink.secondary
                piece.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Ink.faint)
            case .kept:
                piece.foregroundColor = Ink.primary
                piece.font = Kind.display.weight(.semibold)
            }
            result += piece
        }
    }
}

extension RepairResolution {
    var accent: Color { isProblem ? Ink.attention : Ink.faint }
}
