import XCTest
@testable import Speek

final class KokoroVoiceCatalogTests: XCTestCase {

    func test_catalog_ids_round_trip_to_packs() {
        for voice in KokoroVoiceCatalog.voices {
            XCTAssertEqual(KokoroVoiceCatalog.pack(fromIdentifier: voice.id), voice.pack)
            XCTAssertEqual(KokoroVoiceCatalog.voice(forIdentifier: voice.id), voice)
        }
    }

    func test_packs_are_unique_and_well_formed() {
        let packs = KokoroVoiceCatalog.voices.map(\.pack)
        XCTAssertEqual(Set(packs).count, packs.count)
        for pack in packs {
            // a/b (American/British) + f/m + underscore + name.
            XCTAssertTrue(pack.hasPrefix("af_") || pack.hasPrefix("am_")
                          || pack.hasPrefix("bf_") || pack.hasPrefix("bm_"),
                          "unexpected pack prefix: \(pack)")
        }
    }

    func test_default_voice_is_in_catalog() {
        XCTAssertNotNil(KokoroVoiceCatalog.voice(forIdentifier: NeuralSpeechEngine.defaultVoiceIdentifier))
    }

    func test_non_neural_ids_yield_no_pack() {
        XCTAssertNil(KokoroVoiceCatalog.pack(fromIdentifier: ""))
        XCTAssertNil(KokoroVoiceCatalog.pack(fromIdentifier: "com.apple.voice.premium.en-US.Ava"))
    }

    func test_unknown_but_well_formed_neural_id_passes_through() {
        // Forward compatibility: a future version may persist packs we don't
        // list yet — they should still parse.
        XCTAssertEqual(KokoroVoiceCatalog.pack(fromIdentifier: "kokoro:af_future"), "af_future")
        XCTAssertNil(KokoroVoiceCatalog.voice(forIdentifier: "kokoro:af_future"))
    }

    func test_malformed_neural_ids_rejected() {
        XCTAssertNil(KokoroVoiceCatalog.pack(fromIdentifier: "kokoro:"))
        XCTAssertNil(KokoroVoiceCatalog.pack(fromIdentifier: "kokoro:../etc/passwd"))
        XCTAssertNil(KokoroVoiceCatalog.pack(fromIdentifier: "kokoro:af heart"))
    }
}
