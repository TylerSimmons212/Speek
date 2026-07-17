import AppKit

/// Coordinates the "read aloud" entry points — global hotkey and menu bar
/// item — with selection capture and playback.
@MainActor
final class ReadAloudController {
    static let shared = ReadAloudController()
    private init() {}

    /// Hotkey / menu-bar semantics: reading? → stop. Idle? → read the
    /// current selection. Beeps when there's nothing selected so the trigger
    /// never feels dead.
    func toggle() {
        if SpeechService.shared.isSpeaking {
            SpeechService.shared.stop()
            return
        }
        Task { @MainActor in
            guard let text = await SelectedTextReader.shared.captureSelection() else {
                NSSound.beep()
                return
            }
            SpeechService.shared.speak(text)
        }
    }

    func speak(_ text: String) {
        SpeechService.shared.speak(text)
    }
}
