import CoreGraphics
import Foundation

enum Trigger: String, CaseIterable, Sendable {
    case rightCommand
    case rightOption
    case function

    static var current: Trigger {
        UserDefaults.standard.string(forKey: "trigger").flatMap(Trigger.init(rawValue:))
            ?? .rightCommand
    }

    static func select(_ trigger: Trigger) {
        UserDefaults.standard.set(trigger.rawValue, forKey: "trigger")
    }

    var keyCode: Int64 {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .function: 63
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .rightCommand: .maskCommand
        case .rightOption: .maskAlternate
        case .function: .maskSecondaryFn
        }
    }

    var label: String {
        switch self {
        case .rightCommand: "Right Command"
        case .rightOption: "Right Option"
        case .function: "Fn"
        }
    }
}
