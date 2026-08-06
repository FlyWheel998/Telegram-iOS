import Foundation

/// Persistence seam. The app binds this to UserDefaults; tests bind an in-memory double,
/// which keeps the store's behaviour verifiable without a device.
public protocol SGRemovalRuleStorage: AnyObject {
    func loadRaw() -> Data?
    func saveRaw(_ data: Data?)
}

public final class SGInMemoryRuleStorage: SGRemovalRuleStorage {
    private var data: Data?
    public init(seed: Data? = nil) { self.data = seed }
    public func loadRaw() -> Data? { return self.data }
    public func saveRaw(_ data: Data?) { self.data = data }
}

public final class SGUserDefaultsRuleStorage: SGRemovalRuleStorage {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "sgTextRemovalRules") {
        self.defaults = defaults
        self.key = key
    }

    public func loadRaw() -> Data? { return self.defaults.data(forKey: self.key) }
    public func saveRaw(_ data: Data?) {
        if let data { self.defaults.set(data, forKey: self.key) }
        else { self.defaults.removeObject(forKey: self.key) }
    }
}

public enum SGRuleRejection: Error, Equatable {
    /// Selection was empty, or whitespace only.
    case empty
    /// Selections this short match far too much to be a footer, and would mangle every post.
    case tooShort(minimum: Int)
    /// An equivalent rule already exists for this chat.
    case duplicate(existingId: String)
}

/// Thread-safe store of per-channel removal rules.
///
/// Reads happen from message-layout work off the main thread, so the cache is lock-guarded.
/// Rules are cached in memory and only re-decoded when mutated, since `rules(forPeerId:)`
/// is called for every message that gets laid out.
public final class SGRemovalRuleStore {
    public static let minimumRuleLength = 2

    private let storage: SGRemovalRuleStorage
    private let lock = NSLock()
    private var cache: [SGRemovalRule]

    public init(storage: SGRemovalRuleStorage) {
        self.storage = storage
        self.cache = SGRemovalRuleStore.decode(storage.loadRaw())
    }

    private static func decode(_ data: Data?) -> [SGRemovalRule] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([SGRemovalRule].self, from: data)) ?? []
    }

    private func persistLocked() {
        self.storage.saveRaw(try? JSONEncoder().encode(self.cache))
    }

    // MARK: Queries

    public func allRules() -> [SGRemovalRule] {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.cache
    }

    public func rules(forPeerId peerId: Int64) -> [SGRemovalRule] {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.cache.filter { $0.peerId == peerId }
    }

    /// Rules grouped by chat, for the management list.
    public func groupedByPeer() -> [(peerId: Int64, rules: [SGRemovalRule])] {
        self.lock.lock(); defer { self.lock.unlock() }
        let groups = Dictionary(grouping: self.cache, by: { $0.peerId })
        return groups.keys.sorted().map { (peerId: $0, rules: groups[$0] ?? []) }
    }

    // MARK: Mutations

    /// Adds a rule from a text selection. Returns the new rule, or why it was refused.
    ///
    /// Selections routinely arrive with leading/trailing whitespace from an imprecise drag,
    /// so the text is trimmed before validation — otherwise " ad" and "ad " become distinct
    /// rules that both appear to do the same thing.
    public func add(text rawText: String, peerId: Int64) -> Result<SGRemovalRule, SGRuleRejection> {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count >= SGRemovalRuleStore.minimumRuleLength else {
            return .failure(.tooShort(minimum: SGRemovalRuleStore.minimumRuleLength))
        }

        self.lock.lock(); defer { self.lock.unlock() }

        // Compare normalised, so a rule differing only by case, spacing or vowel points
        // is recognised as the one the user already has.
        let incoming = SGTextNormalizer.normalize(text).text
        if let existing = self.cache.first(where: {
            $0.peerId == peerId && SGTextNormalizer.normalize($0.text).text == incoming
        }) {
            return .failure(.duplicate(existingId: existing.id))
        }

        let rule = SGRemovalRule(text: text, peerId: peerId)
        self.cache.append(rule)
        self.persistLocked()
        return .success(rule)
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        let before = self.cache.count
        self.cache.removeAll { $0.id == id }
        guard self.cache.count != before else { return false }
        self.persistLocked()
        return true
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, id: String) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let index = self.cache.firstIndex(where: { $0.id == id }) else { return false }
        guard self.cache[index].isEnabled != enabled else { return true }
        self.cache[index].isEnabled = enabled
        self.persistLocked()
        return true
    }

    @discardableResult
    public func removeAll(forPeerId peerId: Int64) -> Int {
        self.lock.lock(); defer { self.lock.unlock() }
        let before = self.cache.count
        self.cache.removeAll { $0.peerId == peerId }
        let removed = before - self.cache.count
        if removed > 0 { self.persistLocked() }
        return removed
    }

    // MARK: Convenience

    /// True when this chat has no rules, letting render paths skip stripping entirely.
    public func isEmpty(forPeerId peerId: Int64) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return !self.cache.contains { $0.peerId == peerId && $0.isEnabled }
    }
}
