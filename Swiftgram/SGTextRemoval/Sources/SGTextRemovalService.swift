import Foundation

/// Process-wide access point for text removal.
///
/// Message layout runs deep inside view code that has no dependency-injection seam and no
/// reference to anything we own, so a shared instance is the only practical way to reach the
/// rules from a render path. The store beneath it is lock-guarded, and every entry point here
/// is safe to call from the layout threads Telegram uses.
///
/// Kept deliberately small: it holds no UI, imports only Foundation, and is therefore unit
/// testable and usable from modules (such as TextSelectionNode) that must not depend on
/// TelegramCore.
public final class SGTextRemovalService {
    public static let shared = SGTextRemovalService()

    private let store: SGRemovalRuleStore
    private let lock = NSLock()
    private var observers: [UUID: () -> Void] = [:]

    public init(store: SGRemovalRuleStore = SGRemovalRuleStore(storage: SGUserDefaultsRuleStorage())) {
        self.store = store
    }

    // MARK: Reading

    /// Cheap guard for render paths. Most chats have no rules and must cost one lookup.
    public func hasRules(forPeerId peerId: Int64) -> Bool {
        return !self.store.isEmpty(forPeerId: peerId)
    }

    public func rules(forPeerId peerId: Int64) -> [SGRemovalRule] {
        return self.store.rules(forPeerId: peerId)
    }

    public func allRules() -> [SGRemovalRule] {
        return self.store.allRules()
    }

    public func groupedByPeer() -> [(peerId: Int64, rules: [SGRemovalRule])] {
        return self.store.groupedByPeer()
    }

    /// Applies every enabled rule for this chat.
    ///
    /// Ranges are UTF-16, matching `MessageTextEntity.range`. Returns the input unchanged when
    /// nothing matches, so callers can skip downstream work by identity.
    public func strip(
        text: String,
        entityRanges: [NSRange],
        peerId: Int64
    ) -> (text: String, mappedRanges: [NSRange?]) {
        guard self.hasRules(forPeerId: peerId) else {
            return (text, entityRanges.map { Optional($0) })
        }
        return SGTextRemover.strip(
            text: text,
            entityRanges: entityRanges,
            rules: self.store.rules(forPeerId: peerId),
            peerId: peerId
        )
    }

    /// Convenience for callers with no entities to preserve (chat-list previews, accessibility text).
    public func strip(text: String, peerId: Int64) -> String {
        return self.strip(text: text, entityRanges: [], peerId: peerId).text
    }

    // MARK: Writing

    @discardableResult
    public func add(text: String, peerId: Int64) -> Result<SGRemovalRule, SGRuleRejection> {
        let result = self.store.add(text: text, peerId: peerId)
        if case .success = result { self.notifyObservers() }
        return result
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        let removed = self.store.remove(id: id)
        if removed { self.notifyObservers() }
        return removed
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, id: String) -> Bool {
        let changed = self.store.setEnabled(enabled, id: id)
        if changed { self.notifyObservers() }
        return changed
    }

    @discardableResult
    public func removeAll(forPeerId peerId: Int64) -> Int {
        let count = self.store.removeAll(forPeerId: peerId)
        if count > 0 { self.notifyObservers() }
        return count
    }

    // MARK: Change notification

    /// SGSimpleSettings has no change-observation mechanism, and adding a rule must take effect
    /// immediately - the user selects text, taps Remove, and expects it gone from the open chat.
    /// Waiting for a natural repaint is not acceptable for that path, so mutations broadcast here
    /// and the chat controller forces a redraw.
    public func observeChanges(_ handler: @escaping () -> Void) -> SGRemovalObservation {
        let id = UUID()
        self.lock.lock()
        self.observers[id] = handler
        self.lock.unlock()
        return SGRemovalObservation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    private func notifyObservers() {
        self.lock.lock()
        let handlers = Array(self.observers.values)
        self.lock.unlock()
        for handler in handlers {
            handler()
        }
    }
}

/// Cancels an observation when released, so callers cannot leak handlers by forgetting to detach.
public final class SGRemovalObservation {
    private let onCancel: () -> Void
    private var isCancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        guard !self.isCancelled else { return }
        self.isCancelled = true
        self.onCancel()
    }

    deinit {
        self.cancel()
    }
}
