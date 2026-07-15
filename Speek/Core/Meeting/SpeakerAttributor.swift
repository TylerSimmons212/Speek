import Foundation

/// Decides who spoke in a flushed audio window, given per-track activity
/// stats. Coarse two-party diarization for free: the mic track is "You",
/// the system-audio track is "Them".
///
/// The bleed rule handles laptop-speaker setups, where the mic also hears
/// the other participants: when both tracks look active but one is much
/// quieter, the quiet one is almost certainly picking up the loud one's
/// audio secondhand and gets dropped. (Headphones make separation exact.)
enum SpeakerAttributor {
    struct TrackActivity: Equatable {
        var totalDuration: TimeInterval = 0
        /// Time spent above the speech threshold.
        var activeDuration: TimeInterval = 0
        /// Sum of RMS over active stretches (for mean energy comparison).
        var activeEnergySum: Float = 0
        var activeChunks: Int = 0

        mutating func observe(rms: Float, duration: TimeInterval, threshold: Float) {
            totalDuration += duration
            if rms >= threshold {
                activeDuration += duration
                activeEnergySum += rms
                activeChunks += 1
            }
        }

        var meanActiveEnergy: Float {
            activeChunks > 0 ? activeEnergySum / Float(activeChunks) : 0
        }
    }

    struct Verdict: Equatable {
        var you: Bool
        var them: Bool
    }

    /// A track "spoke" if it was active for at least `minActiveDuration`
    /// or 8% of the window, whichever is larger.
    static let minActiveDuration: TimeInterval = 0.4
    /// Both active but one below this fraction of the other's energy → bleed.
    static let bleedEnergyRatio: Float = 0.25

    static func attribute(mic: TrackActivity, system: TrackActivity) -> Verdict {
        let micSpoke = isActive(mic)
        let systemSpoke = isActive(system)

        guard micSpoke, systemSpoke else {
            return Verdict(you: micSpoke, them: systemSpoke)
        }

        // Both hot: reject the one that's likely secondhand audio.
        let micEnergy = mic.meanActiveEnergy
        let systemEnergy = system.meanActiveEnergy
        if micEnergy < systemEnergy * bleedEnergyRatio {
            return Verdict(you: false, them: true)
        }
        if systemEnergy < micEnergy * bleedEnergyRatio {
            return Verdict(you: true, them: false)
        }
        // Genuine crosstalk — keep both.
        return Verdict(you: true, them: true)
    }

    private static func isActive(_ track: TrackActivity) -> Bool {
        guard track.totalDuration > 0 else { return false }
        let requirement = max(minActiveDuration, track.totalDuration * 0.08)
        return track.activeDuration >= requirement
    }
}
