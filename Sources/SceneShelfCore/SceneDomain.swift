import Foundation

/// A stable identifier for a saved scene.
public typealias SceneID = String

/// The deliberately small state machine used by the P0-1 fake shelf.
public enum SceneState: String, CaseIterable, Equatable, Sendable {
    case stashed
    case preparing
    case displayed
    case partiallyRestored
    case failed

    public var japaneseLabel: String {
        switch self {
        case .stashed:
            return "しまい済み"
        case .preparing:
            return "準備中"
        case .displayed:
            return "表示中"
        case .partiallyRestored:
            return "一部復元"
        case .failed:
            return "失敗"
        }
    }
}

/// The serializable, Sendable part of a scene definition.
public struct SceneDefinition: Equatable, Sendable, Identifiable {
    public let id: SceneID
    public let name: String

    public init(id: SceneID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SceneCardSnapshot: Equatable, Sendable, Identifiable {
    public let id: SceneID
    public let name: String
    public let state: SceneState

    public init(id: SceneID, name: String, state: SceneState) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public struct SceneShelfSnapshot: Equatable, Sendable {
    public let cards: [SceneCardSnapshot]

    public init(cards: [SceneCardSnapshot]) {
        self.cards = cards
    }
}

public enum SceneClickOutcome: Equatable, Sendable {
    case completed(sceneID: SceneID, state: SceneState)
    case busyRejected(sceneID: SceneID)
    case sceneNotFound(sceneID: SceneID)
    case emptyShelf
}

public enum FakeSceneFactory {
    public static let defaultScenes: [SceneDefinition] = [
        SceneDefinition(id: "development", name: "開発"),
        SceneDefinition(id: "meeting", name: "会議")
    ]
}
