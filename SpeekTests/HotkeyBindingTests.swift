import XCTest
import CoreGraphics
@testable import Speek

final class HotkeyBindingTests: XCTestCase {

    func test_json_round_trip_modifier() {
        let binding = HotkeyBinding.modifier(flagRawValue: CGEventFlags.maskAlternate.rawValue, keyCode: 61)
        let json = binding.jsonString
        XCTAssertNotNil(json)
        XCTAssertEqual(HotkeyBinding.from(jsonString: json!), binding)
    }

    func test_json_round_trip_function_key() {
        let binding = HotkeyBinding.functionKey(keyCode: 105)
        XCTAssertEqual(HotkeyBinding.from(jsonString: binding.jsonString!), binding)
    }

    func test_legacy_migration() {
        XCTAssertEqual(HotkeyBinding.fromLegacyChoice("fn"), .fn)
        XCTAssertEqual(HotkeyBinding.fromLegacyChoice("rightOption"), .rightOption)
        XCTAssertEqual(HotkeyBinding.fromLegacyChoice("rightCommand"), .rightCommand)
        XCTAssertNil(HotkeyBinding.fromLegacyChoice("garbage"))
    }

    func test_modifier_flag_mapping() {
        XCTAssertEqual(HotkeyBinding.modifierFlag(forKeyCode: 63), .maskSecondaryFn)
        XCTAssertEqual(HotkeyBinding.modifierFlag(forKeyCode: 54), .maskCommand)
        XCTAssertEqual(HotkeyBinding.modifierFlag(forKeyCode: 55), .maskCommand)
        XCTAssertEqual(HotkeyBinding.modifierFlag(forKeyCode: 58), .maskAlternate)
        XCTAssertEqual(HotkeyBinding.modifierFlag(forKeyCode: 61), .maskAlternate)
        XCTAssertEqual(HotkeyBinding.modifierFlag(forKeyCode: 59), .maskControl)
        XCTAssertEqual(HotkeyBinding.modifierFlag(forKeyCode: 60), .maskShift)
        XCTAssertNil(HotkeyBinding.modifierFlag(forKeyCode: 0)) // 'a'
        XCTAssertNil(HotkeyBinding.modifierFlag(forKeyCode: 105)) // F13 is not a modifier
    }

    func test_display_names() {
        XCTAssertEqual(HotkeyBinding.fn.displayName, "Fn (Globe)")
        XCTAssertEqual(HotkeyBinding.rightCommand.displayName, "Right ⌘")
        XCTAssertEqual(HotkeyBinding.rightOption.displayName, "Right ⌥")
        XCTAssertEqual(HotkeyBinding.functionKey(keyCode: 105).displayName, "F13")
        XCTAssertEqual(HotkeyBinding.functionKey(keyCode: 90).displayName, "F20")
    }

    func test_keycap_labels() {
        XCTAssertEqual(HotkeyBinding.fn.keycapLabel, "Fn")
        XCTAssertEqual(HotkeyBinding.rightCommand.keycapLabel, "R⌘")
        XCTAssertEqual(HotkeyBinding.functionKey(keyCode: 113).keycapLabel, "F15")
    }

    func test_function_key_codes_cover_f13_to_f20() {
        XCTAssertEqual(HotkeyBinding.functionKeyCodes.count, 8)
        XCTAssertTrue(HotkeyBinding.functionKeyCodes.contains(105)) // F13
        XCTAssertTrue(HotkeyBinding.functionKeyCodes.contains(90))  // F20
        XCTAssertFalse(HotkeyBinding.functionKeyCodes.contains(122)) // F1
    }

    func test_flag_accessor() {
        XCTAssertEqual(HotkeyBinding.fn.flag, .maskSecondaryFn)
        XCTAssertNil(HotkeyBinding.functionKey(keyCode: 105).flag)
    }
}
