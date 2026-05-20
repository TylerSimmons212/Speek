import Foundation

protocol KVBackend {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension UserDefaults: KVBackend {}

/// Local settings storage. Reads/writes go to UserDefaults.standard in production.
final class SyncStore {
    private let backend: KVBackend
    init(backend: KVBackend = UserDefaults.standard) {
        self.backend = backend
    }

    func string(forKey key: String) -> String? { backend.object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { (backend.object(forKey: key) as? Bool) ?? false }
    func hasValue(forKey key: String) -> Bool { backend.object(forKey: key) != nil }
    func setString(_ value: String, forKey key: String) {
        backend.set(value, forKey: key); backend.synchronize()
    }
    func setBool(_ value: Bool, forKey key: String) {
        backend.set(value, forKey: key); backend.synchronize()
    }

    /// Encodes/decodes a [String: String] dictionary as JSON. Stored as a String
    /// so it travels alongside the rest of the simple-typed settings.
    func stringDictionary(forKey key: String) -> [String: String] {
        guard let raw = backend.object(forKey: key) as? String,
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    func setStringDictionary(_ value: [String: String], forKey key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8) else { return }
        backend.set(raw, forKey: key); backend.synchronize()
    }
}
