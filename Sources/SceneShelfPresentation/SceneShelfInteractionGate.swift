import SceneShelfCore

/// Serializes the two independent actions exposed by a saved-scene card.
///
/// SwiftUI can deliver the card button action before the management menu item
/// action for the same mouse event. The primary request therefore remains
/// pending until the caller explicitly consumes it. A management declaration
/// synchronously invalidates pending requests while management owns the shelf.
@MainActor
public final class SceneShelfInteractionGate {
    public struct PrimaryRequest: Equatable, Sendable {
        fileprivate let sceneID: SceneID
        fileprivate let sequence: UInt64
    }

    public struct ManagementScope: Equatable, Hashable, Sendable {
        fileprivate let sceneID: SceneID
        fileprivate let sequence: UInt64
    }

    private var nextSequence: UInt64 = 0
    private var pendingPrimaryRequests: [SceneID: PrimaryRequest] = [:]
    private var activeManagementScopes: Set<ManagementScope> = []

    public init() {}

    /// Starts a primary request. Only the latest request for a scene can run.
    public func requestPrimary(sceneID: SceneID) -> PrimaryRequest {
        nextSequence &+= 1
        let request = PrimaryRequest(sceneID: sceneID, sequence: nextSequence)
        pendingPrimaryRequests[sceneID] = request
        return request
    }

    /// Starts a management action for a scene. Any pending primary request
    /// for the shelf are cancelled, and new primary requests are blocked until
    /// the returned scope is ended.
    public func beginManagement(sceneID: SceneID) -> ManagementScope {
        nextSequence &+= 1
        let scope = ManagementScope(sceneID: sceneID, sequence: nextSequence)
        activeManagementScopes.insert(scope)
        pendingPrimaryRequests.removeAll()
        return scope
    }

    /// Ends a management action if it is still the active scope for its scene.
    public func endManagement(_ scope: ManagementScope) {
        activeManagementScopes.remove(scope)
    }

    /// Consumes a primary request exactly once if no management action owns
    /// any card in the shelf.
    public func consumePrimary(_ request: PrimaryRequest) -> Bool {
        guard activeManagementScopes.isEmpty else {
            return false
        }
        guard pendingPrimaryRequests[request.sceneID] == request else {
            return false
        }
        pendingPrimaryRequests.removeValue(forKey: request.sceneID)
        return true
    }
}
