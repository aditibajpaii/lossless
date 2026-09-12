import AppKit
import Foundation
import LosslessKit

@MainActor
enum Cues {
    private static let key = "soundCues"
    private static var cache: [SessionEffect.Cue: NSSound] = [:]

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func play(_ cue: SessionEffect.Cue) {
        guard enabled else { return }
        let sound = cache[cue] ?? NSSound(named: name(cue))
        guard let sound else { return }
        cache[cue] = sound
        sound.volume = 0.35
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private static func name(_ cue: SessionEffect.Cue) -> String {
        switch cue {
        case .start: "Tink"
        case .stop: "Pop"
        case .error: "Funk"
        }
    }
}
