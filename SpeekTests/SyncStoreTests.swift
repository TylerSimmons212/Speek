import XCTest
@testable import Speek

final class SyncStoreTests: XCTestCase {
    func test_set_and_get_string() {
        let store = SyncStore(backend: InMemoryKVBackend())
        store.setString("fn", forKey: "hotkey")
        XCTAssertEqual(store.string(forKey: "hotkey"), "fn")
    }

    func test_set_and_get_bool() {
        let store = SyncStore(backend: InMemoryKVBackend())
        store.setBool(true, forKey: "fmEnabled")
        XCTAssertTrue(store.bool(forKey: "fmEnabled"))
    }

    func test_returns_nil_for_missing_key() {
        let store = SyncStore(backend: InMemoryKVBackend())
        XCTAssertNil(store.string(forKey: "nope"))
    }
}

final class InMemoryKVBackend: KVBackend {
    private var data: [String: Any] = [:]
    func object(forKey key: String) -> Any? { data[key] }
    func set(_ value: Any?, forKey key: String) { data[key] = value }
    func synchronize() -> Bool { true }
}
