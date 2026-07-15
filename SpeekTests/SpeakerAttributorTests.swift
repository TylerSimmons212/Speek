import XCTest
@testable import Speek

final class SpeakerAttributorTests: XCTestCase {

    private func track(active: TimeInterval, total: TimeInterval, energy: Float) -> SpeakerAttributor.TrackActivity {
        var t = SpeakerAttributor.TrackActivity()
        // Simulate: `active` seconds above threshold at `energy`, rest silent.
        if active > 0 {
            t.observe(rms: energy, duration: active, threshold: 0.012)
        }
        if total - active > 0 {
            t.observe(rms: 0.001, duration: total - active, threshold: 0.012)
        }
        return t
    }

    func test_only_them_speaking() {
        let verdict = SpeakerAttributor.attribute(
            mic: track(active: 0, total: 8, energy: 0),
            system: track(active: 6, total: 8, energy: 0.1)
        )
        XCTAssertEqual(verdict, .init(you: false, them: true))
    }

    func test_only_you_speaking() {
        let verdict = SpeakerAttributor.attribute(
            mic: track(active: 5, total: 8, energy: 0.09),
            system: track(active: 0.1, total: 8, energy: 0.02)
        )
        XCTAssertEqual(verdict, .init(you: true, them: false))
    }

    func test_neither_speaking() {
        let verdict = SpeakerAttributor.attribute(
            mic: track(active: 0.2, total: 8, energy: 0.02),
            system: track(active: 0.1, total: 8, energy: 0.02)
        )
        XCTAssertEqual(verdict, .init(you: false, them: false))
    }

    func test_genuine_crosstalk_keeps_both() {
        let verdict = SpeakerAttributor.attribute(
            mic: track(active: 4, total: 8, energy: 0.08),
            system: track(active: 4, total: 8, energy: 0.1)
        )
        XCTAssertEqual(verdict, .init(you: true, them: true))
    }

    func test_speaker_bleed_into_mic_dropped() {
        // Laptop speakers: mic hears the call quietly. Mic energy far below
        // system energy → the mic activity is secondhand, drop You.
        let verdict = SpeakerAttributor.attribute(
            mic: track(active: 4, total: 8, energy: 0.02),
            system: track(active: 4, total: 8, energy: 0.12)
        )
        XCTAssertEqual(verdict, .init(you: false, them: true))
    }

    func test_system_bleed_dropped() {
        let verdict = SpeakerAttributor.attribute(
            mic: track(active: 4, total: 8, energy: 0.12),
            system: track(active: 4, total: 8, energy: 0.02)
        )
        XCTAssertEqual(verdict, .init(you: true, them: false))
    }

    func test_short_blip_not_active() {
        // 0.3s of noise in an 8s window isn't speech.
        let verdict = SpeakerAttributor.attribute(
            mic: track(active: 0.3, total: 8, energy: 0.1),
            system: track(active: 5, total: 8, energy: 0.1)
        )
        XCTAssertEqual(verdict, .init(you: false, them: true))
    }

    func test_empty_tracks() {
        let verdict = SpeakerAttributor.attribute(
            mic: SpeakerAttributor.TrackActivity(),
            system: SpeakerAttributor.TrackActivity()
        )
        XCTAssertEqual(verdict, .init(you: false, them: false))
    }
}
