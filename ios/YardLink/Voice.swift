import AVFoundation
import Foundation

/// Short spoken prompts for a driver who should keep their eyes on the road:
/// a welcome after sign-in, and a heads-up when nearing and reaching the
/// drop-off. Other audio ducks while a prompt plays, and podcasts pause.
/// Drivers can turn them off under More.
@MainActor
final class Voice: NSObject {
    static let shared = Voice()

    /// The More screen's switch. On unless the driver turned it off.
    static let enabledKey = "yardlink.voicePrompts"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Say this now, after anything already playing. Nothing when turned off.
    func say(_ text: String) {
        guard Self.isEnabled, !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// The prompt for nearing where the trip is headed.
    static func approaching(_ place: String) -> String {
        "Approaching \(place). About a mile out."
    }

    /// The prompt for pulling in.
    static func arriving(_ place: String) -> String {
        "Arriving at \(place). Don't forget to confirm your arrival and record the drop-off in Yard Link."
    }

    /// The greeting once sign-in finishes.
    static func welcome(_ firstName: String) -> String {
        firstName.isEmpty ? "Welcome to Yard Link." : "Welcome back, \(firstName)."
    }
}

extension Voice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in Voice.shared.releaseAudio(after: synthesizer) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in Voice.shared.releaseAudio(after: synthesizer) }
    }

    /// Hand the speakers back once the last prompt is done, so music comes back up.
    private func releaseAudio(after synthesizer: AVSpeechSynthesizer) {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
