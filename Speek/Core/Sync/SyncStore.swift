import Foundation

protocol KVBackend {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KVBackend {}

/// Cross-Mac settings storage. Reads/writes go to NSUbiquitousKeyValueStore in production.
final class SyncStore {
    private let backend: KVBackend
    init(backend: KVBackend = NSUbiquitousKeyValueStore.default) {
        self.backend = backend
    }

    func string(forKey key: String) -> String? { backend.object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { (backend.object(forKey: key) as? Bool) ?? false }
    func setString(_ value: String, forKey key: String) {
        backend.set(value, forKey: key); backend.synchronize()
    }
    func setBool(_ value: Bool, forKey key: String) {
        backend.set(value, forKey: key); backend.synchronize()
    }
}
