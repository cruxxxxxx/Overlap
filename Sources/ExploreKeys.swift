import Combine
import Foundation

/// What a key can do on the Explore page.
enum ExploreAction: String, Codable, CaseIterable, Identifiable {
    case like, less, nextImage, nextBatch, quickLook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .like:
            return "Like"
        case .less:
            return "Less like this"
        case .nextImage:
            return "Next image (on the last, next batch)"
        case .nextBatch:
            return "Next batch"
        case .quickLook:
            return "Quick Look"
        }
    }
}

struct ExploreKey: Codable, Equatable {
    let keyCode: UInt16
    let label: String
}

/// Explore's bare keys, one per action. They only apply on the Explore page,
/// outside text fields, so Q and W don't touch ⌘Q and ⌘W.
struct ExploreKeymap: Codable, Equatable {
    static let defaults: [ExploreAction: ExploreKey] = [
        .like: ExploreKey(keyCode: 12, label: "Q"),
        .less: ExploreKey(keyCode: 13, label: "W"),
        .nextImage: ExploreKey(keyCode: 49, label: "Space"),
        .nextBatch: ExploreKey(keyCode: 14, label: "E"),
        .quickLook: ExploreKey(keyCode: 15, label: "R"),
    ]

    /// Keep their meaning everywhere: T tags, arrows move, Esc cancels a
    /// recording, Tab moves focus, Delete edits.
    static let reservedKeyCodes: Set<UInt16> = [17, 123, 124, 125, 126, 53, 48, 51]

    private var keys: [ExploreAction: ExploreKey] = [:]

    func key(for action: ExploreAction) -> ExploreKey {
        keys[action] ?? Self.defaults[action]!
    }

    func action(forKeyCode keyCode: UInt16) -> ExploreAction? {
        ExploreAction.allCases.first { key(for: $0).keyCode == keyCode }
    }

    /// A key already in use trades places, so every action keeps exactly one key.
    /// False for a reserved key.
    @discardableResult
    mutating func assign(_ newKey: ExploreKey, to action: ExploreAction) -> Bool {
        guard !Self.reservedKeyCodes.contains(newKey.keyCode) else {
            return false
        }
        let previous = key(for: action)
        if let holder = self.action(forKeyCode: newKey.keyCode), holder != action {
            keys[holder] = previous
        }
        keys[action] = newKey
        return true
    }
}

@MainActor
final class ExploreKeyBindings: ObservableObject {
    static let shared = ExploreKeyBindings()
    private static let defaultsKey = "exploreKeymap"

    @Published private(set) var keymap: ExploreKeymap

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.defaultsKey)
        keymap = saved.flatMap { try? JSONDecoder().decode(ExploreKeymap.self, from: $0) } ?? ExploreKeymap()
    }

    func label(_ action: ExploreAction) -> String {
        keymap.key(for: action).label
    }

    func assign(_ key: ExploreKey, to action: ExploreAction) -> Bool {
        guard keymap.assign(key, to: action) else {
            return false
        }
        persist()
        return true
    }

    func reset() {
        keymap = ExploreKeymap()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(keymap) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
