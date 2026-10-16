import XCTest
@testable import Speek

final class AppPolishStyleTests: XCTestCase {
    func test_chat_apps_get_semi_casual_prose() {
        for id in ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.microsoft.teams2"] {
            XCTAssertEqual(
                AppPolishStyle.style(forBundleID: id),
                PolishStyle(styling: .semiCasual, structure: .prose, context: .general),
                id
            )
        }
    }

    func test_mail_apps_get_email_context() {
        for id in ["com.apple.mail", "com.microsoft.Outlook"] {
            XCTAssertEqual(
                AppPolishStyle.style(forBundleID: id),
                PolishStyle(styling: .semiFormal, structure: .prose, context: .email),
                id
            )
        }
    }

    func test_unknown_and_missing_apps_get_standard() {
        XCTAssertEqual(AppPolishStyle.style(forBundleID: "com.apple.dt.Xcode"), .standard)
        XCTAssertEqual(AppPolishStyle.style(forBundleID: nil), .standard)
    }

    func test_no_app_is_both_chat_and_email() {
        XCTAssertTrue(AppPolishStyle.chatBundleIDs.isDisjoint(with: AppPolishStyle.emailBundleIDs))
    }

    /// Implicit styles must never use `casual` (strips apostrophes) or
    /// `lists` (no observed effect; prose already bullets real lists).
    func test_mapped_styles_avoid_casual_and_lists() {
        for style in [AppPolishStyle.chat, AppPolishStyle.email] {
            XCTAssertNotEqual(style.styling, .casual)
            XCTAssertEqual(style.structure, .prose)
        }
    }
}
