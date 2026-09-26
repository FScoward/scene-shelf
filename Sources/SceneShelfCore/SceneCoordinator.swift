import Foundation

public typealias SceneOperation = @Sendable (_ scene: SceneDefinition, _ destination: SceneState) async -> Void

/// Serializes scene clicks so the shelf cannot queue an accidental second action.
public actor SceneCoordinator {
    private struct Card: Sendable {
        let definition: SceneDefinition
        var state: SceneState
    }

    private var cards: [Card]
    private var isBusy = false
    private let operation: SceneOperation

    public init(
        scenes: [SceneDefinition],
        initialState: SceneState = .stashed,
        operation: @escaping SceneOperation = { _, _ in }
    ) {
        self.cards = scenes.map { Card(definition: $0, state: initialState) }
        self.operation = operation
    }

    public func snapshot() -> SceneShelfSnapshot {
        SceneShelfSnapshot(
            cards: cards.map {
                SceneCardSnapshot(id: $0.definition.id, name: $0.definition.name, state: $0.state)
            }
        )
    }

    public func click(sceneID: SceneID) async -> SceneClickOutcome {
        guard !cards.isEmpty else {
            return .emptyShelf
        }

        guard let cardIndex = cards.firstIndex(where: { $0.definition.id == sceneID }) else {
            return .sceneNotFound(sceneID: sceneID)
        }

        guard !isBusy else {
            return .busyRejected(sceneID: sceneID)
        }

        let destination: SceneState
        switch cards[cardIndex].state {
        case .stashed:
            destination = .displayed
        case .displayed:
            destination = .stashed
        case .partiallyRestored, .failed:
            destination = .displayed
        case .preparing:
            return .busyRejected(sceneID: sceneID)
        }

        isBusy = true
        cards[cardIndex].state = .preparing
        let definition = cards[cardIndex].definition

        await operation(definition, destination)

        cards[cardIndex].state = destination
        isBusy = false
        return .completed(sceneID: sceneID, state: destination)
    }
}
