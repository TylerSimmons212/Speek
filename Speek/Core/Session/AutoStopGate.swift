import Foundation

/// Ends a latched (double-tap) recording automatically once the speaker is
/// done: some speech must have been heard, then a trailing pause. RMS-based
/// and deliberately simple — no extra model, no extra latency. Push-to-talk
/// holds never use this: a held key is an explicit "keep going".
///
/// Levels are DictationSession's scaled RMS (raw × 4, capped at 1), where
/// typical speech sits around 0.3–0.9.
struct AutoStopGate {
    /// Below this is silence.
    var silenceThreshold: Float = 0.05
    /// At or above this counts as speech. The band between the two
    /// thresholds (breath, room tone, trailing consonants) counts as
    /// neither: it doesn't reset the pause, and doesn't extend it.
    var speechThreshold: Float = 0.12
    /// Trailing pause that ends the recording.
    var silenceHold: TimeInterval = 1.6
    /// Ignore everything until this much cumulative speech has been heard —
    /// latching and then gathering your thoughts must not instantly stop.
    var minSpeech: TimeInterval = 0.4

    private var speechTime: TimeInterval = 0
    private var silenceRun: TimeInterval = 0

    /// Feed one audio chunk's level; returns true when the recording should
    /// stop now.
    mutating func observe(rms: Float, duration: TimeInterval) -> Bool {
        if rms >= speechThreshold {
            speechTime += duration
            silenceRun = 0
        } else if rms < silenceThreshold {
            silenceRun += duration
        }
        return speechTime >= minSpeech && silenceRun >= silenceHold
    }

    mutating func reset() {
        speechTime = 0
        silenceRun = 0
    }
}
