import Foundation

public struct SceneWindowIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let bundleIdentifier: String
    public let processID: Int32
    public let title: String
    public let identifier: String?

    public var id: String {
        let stablePart = identifier ?? title
        return "\(bundleIdentifier):\(processID):\(stablePart)"
    }

    public init(
        bundleIdentifier: String,
        processID: Int32,
        title: String,
        identifier: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.title = title
        self.identifier = identifier
    }
}

public struct SceneFrame: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SceneWindowSnapshot: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let identity: SceneWindowIdentity
    public let frame: SceneFrame
    public let isMinimized: Bool

    public var id: String { identity.id }

    public init(identity: SceneWindowIdentity, frame: SceneFrame, isMinimized: Bool) {
        self.identity = identity
        self.frame = frame
        self.isMinimized = isMinimized
    }
}

public struct SavedScene: Codable, Equatable, Sendable, Identifiable {
    public let id: SceneID
    public let name: String
    public let windows: [SceneWindowSnapshot]

    public init(id: SceneID, name: String, windows: [SceneWindowSnapshot]) {
        self.id = id
        self.name = name
        self.windows = windows
    }
}

public enum SceneCaptureError: Error, Equatable, Sendable {
    case emptySelection
    case unregisteredWindow
    case duplicateWindow
}

public enum SceneCaptureFlow {
    public static let defaultName = "Fixture配置"

    public static func capture(
        id: SceneID,
        name: String,
        candidates: [SceneWindowSnapshot],
        selectedIDs: Set<SceneWindowIdentity>
    ) throws -> SavedScene {
        guard !selectedIDs.isEmpty else {
            throw SceneCaptureError.emptySelection
        }

        let candidateIdentities = candidates.map(\.identity)
        guard Set(candidateIdentities).count == candidateIdentities.count else {
            throw SceneCaptureError.duplicateWindow
        }
        guard selectedIDs.allSatisfy({ candidateIdentities.contains($0) }) else {
            throw SceneCaptureError.unregisteredWindow
        }

        let selected = candidates.filter { selectedIDs.contains($0.identity) }
        guard !selected.isEmpty else {
            throw SceneCaptureError.emptySelection
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return SavedScene(
            id: id,
            name: normalizedName.isEmpty ? defaultName : normalizedName,
            windows: selected
        )
    }
}

public enum SceneFailureReason: String, Error, Equatable, Sendable {
    case permissionDenied
    case applicationUnavailable
    case windowMissing
    case ambiguousMatch
    case windowChanged
    case pidReused
    case operationFailed
    case bundleNotAllowed

    public var japaneseLabel: String {
        switch self {
        case .permissionDenied:
            return "アクセシビリティ権限がありません"
        case .applicationUnavailable:
            return "対象アプリが起動していません"
        case .windowMissing:
            return "対象ウィンドウが見つかりません"
        case .ambiguousMatch:
            return "対象ウィンドウを一意に特定できません"
        case .windowChanged:
            return "対象ウィンドウの識別情報が変わりました"
        case .pidReused:
            return "保存時と異なるプロセスIDです"
        case .operationFailed:
            return "ウィンドウ操作に失敗しました"
        case .bundleNotAllowed:
            return "許可されていないBundle IDです"
        }
    }
}

public enum SceneMatchDecision: Equatable, Sendable {
    case matched(SceneWindowSnapshot)
    case ambiguous
    case pidReused
    case windowChanged
    case missing
    case bundleNotAllowed

    public var failureReason: SceneFailureReason? {
        switch self {
        case .matched:
            return nil
        case .ambiguous:
            return .ambiguousMatch
        case .pidReused:
            return .pidReused
        case .windowChanged:
            return .windowChanged
        case .missing:
            return .windowMissing
        case .bundleNotAllowed:
            return .bundleNotAllowed
        }
    }
}

/// Pure value matcher used before an operation becomes a write instruction.
public enum SceneMatcher {
    public static let fixtureBundleIdentifier = "com.fscoward.SceneShelfAXFixture"

    public static func resolve(
        target: SceneWindowIdentity,
        candidates: [SceneWindowSnapshot]
    ) -> SceneMatchDecision {
        guard target.bundleIdentifier == fixtureBundleIdentifier else {
            return .bundleNotAllowed
        }

        let allowedCandidates = candidates.filter {
            $0.identity.bundleIdentifier == fixtureBundleIdentifier
        }
        let exactHints = allowedCandidates.filter {
            $0.identity.title == target.title && $0.identity.identifier == target.identifier
        }
        if exactHints.count > 1 {
            return .ambiguous
        }
        if let exact = exactHints.first {
            return exact.identity.processID == target.processID
                ? .matched(exact)
                : .pidReused
        }

        let samePIDAndIdentifier = allowedCandidates.contains {
            $0.identity.processID == target.processID
                && $0.identity.identifier == target.identifier
        }
        if samePIDAndIdentifier {
            return .windowChanged
        }
        return .missing
    }
}

public enum SceneRestoreAction: String, Equatable, Sendable {
    case display
    case hide
}

public enum SceneWindowOperation: String, Equatable, Sendable {
    case unminimize
    case move
    case resize
    case minimize
}

public struct SceneRestoreInstruction: Equatable, Sendable {
    public let target: SceneWindowIdentity
    public let frame: SceneFrame?
    public let operations: [SceneWindowOperation]

    public init(
        target: SceneWindowIdentity,
        frame: SceneFrame?,
        operations: [SceneWindowOperation]
    ) {
        self.target = target
        self.frame = frame
        self.operations = operations
    }
}

public struct SceneRestorePlan: Equatable, Sendable {
    public let sceneID: SceneID
    public let action: SceneRestoreAction
    public let instructions: [SceneRestoreInstruction]
    public let preflightFailures: [SceneTargetRestoreOutcome]

    public init(
        sceneID: SceneID,
        action: SceneRestoreAction,
        instructions: [SceneRestoreInstruction],
        preflightFailures: [SceneTargetRestoreOutcome] = []
    ) {
        self.sceneID = sceneID
        self.action = action
        self.instructions = instructions
        self.preflightFailures = preflightFailures
    }
}

public struct SceneTargetRestoreOutcome: Equatable, Sendable, Identifiable {
    public let target: SceneWindowIdentity
    public let appliedOperations: [SceneWindowOperation]
    public let failureReason: SceneFailureReason?

    public var id: String { target.id }
    public var succeeded: Bool { failureReason == nil }

    public init(
        target: SceneWindowIdentity,
        appliedOperations: [SceneWindowOperation] = [],
        failureReason: SceneFailureReason? = nil
    ) {
        self.target = target
        self.appliedOperations = appliedOperations
        self.failureReason = failureReason
    }

    public static func succeeded(
        target: SceneWindowIdentity,
        appliedOperations: [SceneWindowOperation]
    ) -> SceneTargetRestoreOutcome {
        SceneTargetRestoreOutcome(
            target: target,
            appliedOperations: appliedOperations
        )
    }

    public static func failed(
        target: SceneWindowIdentity,
        reason: SceneFailureReason,
        appliedOperations: [SceneWindowOperation] = []
    ) -> SceneTargetRestoreOutcome {
        SceneTargetRestoreOutcome(
            target: target,
            appliedOperations: appliedOperations,
            failureReason: reason
        )
    }
}

public struct SceneRestoreReport: Equatable, Sendable {
    public let sceneID: SceneID
    public let action: SceneRestoreAction
    public let outcomes: [SceneTargetRestoreOutcome]

    public var succeededOutcomes: [SceneTargetRestoreOutcome] {
        outcomes.filter(\.succeeded)
    }

    public var failedOutcomes: [SceneTargetRestoreOutcome] {
        outcomes.filter { !$0.succeeded }
    }

    public var state: SceneState {
        guard !outcomes.isEmpty else { return .failed }
        if failedOutcomes.isEmpty {
            return action == .display ? .displayed : .stashed
        }
        if action == .hide {
            return .failed
        }
        return succeededOutcomes.isEmpty ? .failed : .partiallyRestored
    }

    public var currentSceneID: SceneID? {
        if action == .hide {
            // A hide is complete only when every target succeeded. Any
            // failure leaves the scene as the safety anchor for retry/delete
            // protection, even when no target write succeeded.
            return failedOutcomes.isEmpty ? nil : sceneID
        }
        return succeededOutcomes.isEmpty ? nil : sceneID
    }

    public var failureReasons: [SceneFailureReason] {
        var seen = Set<SceneFailureReason>()
        return failedOutcomes.compactMap { outcome in
            guard let reason = outcome.failureReason, seen.insert(reason).inserted else {
                return nil
            }
            return reason
        }
    }

    public init(
        sceneID: SceneID,
        action: SceneRestoreAction,
        outcomes: [SceneTargetRestoreOutcome]
    ) {
        self.sceneID = sceneID
        self.action = action
        self.outcomes = outcomes
    }

    public static func from(
        plan: SceneRestorePlan,
        executedOutcomes: [SceneTargetRestoreOutcome]
    ) -> SceneRestoreReport {
        SceneRestoreReport(
            sceneID: plan.sceneID,
            action: plan.action,
            outcomes: plan.preflightFailures + executedOutcomes
        )
    }

    public static func assuming(
        plan: SceneRestorePlan,
        succeeded: Bool
    ) -> SceneRestoreReport {
        let outcomes = plan.instructions.map { instruction in
            succeeded
                ? SceneTargetRestoreOutcome.succeeded(
                    target: instruction.target,
                    appliedOperations: instruction.operations
                )
                : SceneTargetRestoreOutcome.failed(
                    target: instruction.target,
                    reason: .operationFailed
                )
        }
        return from(plan: plan, executedOutcomes: outcomes)
    }
}

public enum SceneRestorePlanner {
    public static func displayPlan(for scene: SavedScene) -> SceneRestorePlan {
        SceneRestorePlan(
            sceneID: scene.id,
            action: .display,
            instructions: scene.windows.map {
                SceneRestoreInstruction(
                    target: $0.identity,
                    frame: $0.frame,
                    operations: [.unminimize, .move, .resize]
                )
            }
        )
    }

    public static func hidePlan(for scene: SavedScene) -> SceneRestorePlan {
        SceneRestorePlan(
            sceneID: scene.id,
            action: .hide,
            instructions: scene.windows.map {
                SceneRestoreInstruction(
                    target: $0.identity,
                    frame: nil,
                    operations: [.minimize]
                )
            }
        )
    }

    public static func plan(
        for scene: SavedScene,
        candidates: [SceneWindowSnapshot],
        action: SceneRestoreAction
    ) -> SceneRestorePlan {
        let basePlan = action == .display ? displayPlan(for: scene) : hidePlan(for: scene)
        return resolve(plan: basePlan, candidates: candidates)
    }

    /// Only a unique matcher result becomes a write instruction.
    public static func resolve(
        plan: SceneRestorePlan,
        candidates: [SceneWindowSnapshot]
    ) -> SceneRestorePlan {
        var instructions: [SceneRestoreInstruction] = []
        var failures: [SceneTargetRestoreOutcome] = plan.preflightFailures

        for instruction in plan.instructions {
            let decision = SceneMatcher.resolve(
                target: instruction.target,
                candidates: candidates
            )
            guard case .matched = decision else {
                failures.append(
                    .failed(
                        target: instruction.target,
                        reason: decision.failureReason ?? .operationFailed
                    )
                )
                continue
            }
            instructions.append(instruction)
        }

        return SceneRestorePlan(
            sceneID: plan.sceneID,
            action: plan.action,
            instructions: instructions,
            preflightFailures: failures
        )
    }
}

public enum SceneRoundTripOutcome: Equatable, Sendable {
    case displayed(sceneID: SceneID)
    case stashed(sceneID: SceneID)
    case partiallyRestored(sceneID: SceneID)
    case failed(sceneID: SceneID)
    case busyRejected(sceneID: SceneID)
    case sceneNotFound(sceneID: SceneID)
    case emptyStore
    case operationFailed(sceneID: SceneID)
}

public typealias SceneRestoreExecutor = @Sendable (SceneRestorePlan) async -> Bool
public typealias SceneDetailedRestoreExecutor = @Sendable (SceneRestorePlan) async -> SceneRestoreReport

public actor InMemorySceneStore {
    private var storedScenes: [SavedScene] = []
    private var states: [SceneID: SceneState] = [:]
    private var reports: [SceneID: SceneRestoreReport] = [:]
    private let persistence: SceneShelfPersistence?
    private var persistenceEntries: [SceneID: ScenePersistenceIndexEntry] = [:]
    private var persistenceLoadAttempted = false
    private var persistenceLoadFailure: ScenePersistenceError?
    private let persistenceInitializationFailure: ScenePersistenceError?
    private var nextSceneNumber = 1
    private var isBusy = false
    private var currentSceneIDValue: SceneID?

    public init(
        persistence: SceneShelfPersistence? = nil,
        persistenceInitializationFailure: ScenePersistenceError? = nil
    ) {
        self.persistence = persistence
        self.persistenceInitializationFailure = persistenceInitializationFailure
    }

    public func loadPersisted() throws -> ScenePersistenceLoadResult {
        guard !isBusy else {
            throw SceneManagementError.busy
        }
        if let persistenceInitializationFailure {
            persistenceLoadAttempted = true
            persistenceLoadFailure = persistenceInitializationFailure
            throw persistenceInitializationFailure
        }
        guard let persistence else {
            persistenceLoadAttempted = true
            return ScenePersistenceLoadResult(scenes: [], indexEntries: [], diagnostics: [])
        }
        if let persistenceLoadFailure {
            throw persistenceLoadFailure
        }

        do {
            let result = try persistence.load()
            let loadedEntries = Dictionary(
                uniqueKeysWithValues: result.indexEntries.map { ($0.sceneID, $0) }
            )
            let loadedStates: [SceneID: SceneState] = Dictionary(
                uniqueKeysWithValues: result.scenes.map { ($0.id, SceneState.stashed) }
            )
            let loadedNextSceneNumber = try nextSceneNumber(after: result.indexEntries)
            let diskNextSceneNumber = try persistence.nextAvailableSceneNumber(after: loadedNextSceneNumber - 1)

            storedScenes = result.scenes
            persistenceEntries = loadedEntries
            states = loadedStates
            reports.removeAll()
            currentSceneIDValue = nil
            isBusy = false
            nextSceneNumber = diskNextSceneNumber
            persistenceLoadAttempted = true
            return result
        } catch let error as ScenePersistenceError {
            persistenceLoadAttempted = true
            persistenceLoadFailure = error
            throw error
        } catch {
            let persistenceError = ScenePersistenceError.corruptIndex
            persistenceLoadAttempted = true
            persistenceLoadFailure = persistenceError
            throw persistenceError
        }
    }

    /// Retries a previous transient persistence load failure after the caller
    /// repaired the on-disk files. Initialization failures remain terminal.
    public func retryLoadPersisted() throws -> ScenePersistenceLoadResult {
        guard !isBusy else {
            throw SceneManagementError.busy
        }
        guard persistenceInitializationFailure == nil else {
            throw persistenceInitializationFailure!
        }
        persistenceLoadFailure = nil
        return try loadPersisted()
    }

    public func save(
        name: String,
        candidates: [SceneWindowSnapshot],
        selectedIDs: Set<SceneWindowIdentity>
    ) throws -> SavedScene {
        guard !isBusy else {
            throw SceneManagementError.busy
        }
        if persistenceInitializationFailure != nil || persistenceLoadFailure != nil {
            throw ScenePersistenceError.saveRejectedAfterLoadFailure
        }
        if let persistence {
            if !persistenceLoadAttempted {
                do {
                    _ = try loadPersisted()
                } catch {
                    throw ScenePersistenceError.saveRejectedAfterLoadFailure
                }
            }
            if persistenceLoadFailure != nil {
                throw ScenePersistenceError.saveRejectedAfterLoadFailure
            }

            nextSceneNumber = try persistence.nextAvailableSceneNumber(after: nextSceneNumber - 1)
            let reservedNextSceneNumber = try incrementedSceneNumber(nextSceneNumber)

            let scene = try SceneCaptureFlow.capture(
                id: "scene-\(nextSceneNumber)",
                name: name,
                candidates: candidates,
                selectedIDs: selectedIDs
            )
            let order = try nextPersistenceOrder(persistenceEntries.values.map(\.order))
            let entry = ScenePersistenceIndexEntry(
                sceneID: scene.id,
                revision: 1,
                name: scene.name,
                order: order
            )
            let indexEntries = Array(persistenceEntries.values) + [entry]
            try persistence.commit(
                scene: scene,
                revision: entry.revision,
                indexEntries: indexEntries
            )
            nextSceneNumber = reservedNextSceneNumber
            storedScenes.append(scene)
            persistenceEntries[scene.id] = entry
            states[scene.id] = .stashed
            return scene
        }

        let scene = try SceneCaptureFlow.capture(
            id: "scene-\(nextSceneNumber)",
            name: name,
            candidates: candidates,
            selectedIDs: selectedIDs
        )
        let reservedNextSceneNumber = try incrementedSceneNumber(nextSceneNumber)
        storedScenes.append(scene)
        nextSceneNumber = reservedNextSceneNumber
        states[scene.id] = .stashed
        return scene
    }

    public func rename(sceneID: SceneID, name: String) throws -> SavedScene {
        try prepareManagementOperation()
        guard let sceneIndex = storedScenes.firstIndex(where: { $0.id == sceneID }) else {
            throw SceneManagementError.sceneNotFound(sceneID)
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SceneManagementError.emptyName
        }

        let current = storedScenes[sceneIndex]
        let renamed = SavedScene(id: current.id, name: normalizedName, windows: current.windows)
        var entries = orderedPersistenceEntries()
        if let entryIndex = entries.firstIndex(where: { $0.sceneID == sceneID }) {
            let entry = entries[entryIndex]
            entries[entryIndex] = ScenePersistenceIndexEntry(
                sceneID: entry.sceneID,
                revision: entry.revision,
                name: normalizedName,
                order: entry.order
            )
        }
        try commitIndex(entries)
        storedScenes[sceneIndex] = renamed
        persistenceEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.sceneID, $0) })
        return renamed
    }

    public func overwrite(
        sceneID: SceneID,
        candidates: [SceneWindowSnapshot]
    ) throws -> SavedScene {
        try prepareManagementOperation()
        guard let sceneIndex = storedScenes.firstIndex(where: { $0.id == sceneID }) else {
            throw SceneManagementError.sceneNotFound(sceneID)
        }
        let current = storedScenes[sceneIndex]
        guard Set(current.windows.map(\.identity)).count == current.windows.count else {
            throw SceneManagementError.targetUnavailable(.ambiguousMatch)
        }

        let updatedWindows = try current.windows.map { target in
            let decision = SceneMatcher.resolve(target: target.identity, candidates: candidates)
            guard case let .matched(liveSnapshot) = decision else {
                throw SceneManagementError.targetUnavailable(
                    decision.failureReason ?? .operationFailed
                )
            }
            return SceneWindowSnapshot(
                identity: target.identity,
                frame: liveSnapshot.frame,
                isMinimized: liveSnapshot.isMinimized
            )
        }
        let overwritten = SavedScene(id: current.id, name: current.name, windows: updatedWindows)
        let currentRevision = persistenceEntries[sceneID]?.revision ?? 0
        let nextRevision: Int
        if let persistence {
            nextRevision = try persistence.nextAvailableRevision(
                sceneID: sceneID,
                after: currentRevision
            )
        } else {
            nextRevision = currentRevision + 1
        }
        var entries = orderedPersistenceEntries()
        if let entryIndex = entries.firstIndex(where: { $0.sceneID == sceneID }) {
            let entry = entries[entryIndex]
            entries[entryIndex] = ScenePersistenceIndexEntry(
                sceneID: entry.sceneID,
                revision: nextRevision,
                name: entry.name,
                order: entry.order
            )
        }
        try commitRevision(
            scene: overwritten,
            revision: nextRevision,
            entries: entries
        )
        storedScenes[sceneIndex] = overwritten
        persistenceEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.sceneID, $0) })
        return overwritten
    }

    public func duplicate(sceneID: SceneID) throws -> SavedScene {
        try prepareManagementOperation()
        guard let source = storedScenes.first(where: { $0.id == sceneID }) else {
            throw SceneManagementError.sceneNotFound(sceneID)
        }
        if let persistence {
            nextSceneNumber = try persistence.nextAvailableSceneNumber(after: nextSceneNumber - 1)
        }
        let newID = try allocateNextSceneID()
        let reservedNextSceneNumber = try incrementedSceneNumber(nextSceneNumber)
        let duplicate = SavedScene(
            id: newID,
            name: "\(source.name) のコピー",
            windows: source.windows.map {
                SceneWindowSnapshot(
                    identity: $0.identity,
                    frame: $0.frame,
                    isMinimized: $0.isMinimized
                )
            }
        )
        let entry = ScenePersistenceIndexEntry(
            sceneID: newID,
            revision: 1,
            name: duplicate.name,
            order: try nextPersistenceOrder(orderedPersistenceEntries().map(\.order))
        )
        let entries = orderedPersistenceEntries() + [entry]
        try commitRevision(scene: duplicate, revision: 1, entries: entries)
        nextSceneNumber = reservedNextSceneNumber
        storedScenes.append(duplicate)
        persistenceEntries[newID] = entry
        states[newID] = .stashed
        return duplicate
    }

    public func delete(sceneID: SceneID, confirmed: Bool) throws {
        try prepareManagementOperation()
        guard confirmed else {
            throw SceneManagementError.confirmationRequired
        }
        guard let sceneIndex = storedScenes.firstIndex(where: { $0.id == sceneID }) else {
            throw SceneManagementError.sceneNotFound(sceneID)
        }
        switch states[sceneID] ?? .stashed {
        case .displayed, .partiallyRestored, .preparing:
            throw SceneManagementError.sceneActive(sceneID)
        case .stashed:
            break
        case .failed:
            if currentSceneIDValue == sceneID {
                throw SceneManagementError.sceneActive(sceneID)
            }
        }

        let entries = normalizePersistenceEntries(
            orderedPersistenceEntries().filter { $0.sceneID != sceneID }
        )
        try commitIndex(entries)
        storedScenes.remove(at: sceneIndex)
        states.removeValue(forKey: sceneID)
        reports.removeValue(forKey: sceneID)
        persistenceEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.sceneID, $0) })
        if currentSceneIDValue == sceneID {
            currentSceneIDValue = nil
        }
        do {
            try persistence?.cleanupRevisions(for: sceneID)
        } catch {
            throw SceneManagementError.cleanupFailed(sceneID)
        }
    }

    @discardableResult
    public func move(sceneID: SceneID, direction: SceneMoveDirection) throws -> [SavedScene] {
        try prepareManagementOperation()
        guard let index = storedScenes.firstIndex(where: { $0.id == sceneID }) else {
            throw SceneManagementError.sceneNotFound(sceneID)
        }
        let destination: Int
        switch direction {
        case .up:
            destination = index - 1
        case .down:
            destination = index + 1
        }
        guard storedScenes.indices.contains(destination) else {
            throw SceneManagementError.orderBoundary
        }

        var reordered = storedScenes
        reordered.swapAt(index, destination)
        let reorderedIDs = Set(reordered.map(\.id))
        let retainedUnloadedEntries = orderedPersistenceEntries().filter {
            !reorderedIDs.contains($0.sceneID)
        }
        let entries = normalizePersistenceEntries(
            reordered.compactMap { persistenceEntries[$0.id] } + retainedUnloadedEntries
        )
        try commitIndex(entries)
        storedScenes = reordered
        persistenceEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.sceneID, $0) })
        return reordered
    }

    private func prepareManagementOperation() throws {
        guard !isBusy else {
            throw SceneManagementError.busy
        }
        if let persistenceInitializationFailure {
            throw persistenceInitializationFailure
        }
        if let persistenceLoadFailure {
            throw persistenceLoadFailure
        }
        if persistence != nil, !persistenceLoadAttempted {
            _ = try loadPersisted()
        }
    }

    private func commitIndex(_ entries: [ScenePersistenceIndexEntry]) throws {
        guard let persistence else { return }
        try persistence.commitIndex(indexEntries: entries)
    }

    private func commitRevision(
        scene: SavedScene,
        revision: Int,
        entries: [ScenePersistenceIndexEntry]
    ) throws {
        guard let persistence else { return }
        try persistence.commit(
            scene: scene,
            revision: revision,
            indexEntries: entries
        )
    }

    private func orderedPersistenceEntries() -> [ScenePersistenceIndexEntry] {
        persistenceEntries.values.sorted { lhs, rhs in
            if lhs.order == rhs.order {
                return lhs.sceneID < rhs.sceneID
            }
            return lhs.order < rhs.order
        }
    }

    private func normalizePersistenceEntries(
        _ entries: [ScenePersistenceIndexEntry]
    ) -> [ScenePersistenceIndexEntry] {
        entries.enumerated().map { index, entry in
            ScenePersistenceIndexEntry(
                sceneID: entry.sceneID,
                revision: entry.revision,
                name: entry.name,
                order: index
            )
        }
    }

    private func allocateNextSceneID() throws -> SceneID {
        var candidate = "scene-\(nextSceneNumber)"
        while storedScenes.contains(where: { $0.id == candidate }) || persistenceEntries[candidate] != nil {
            nextSceneNumber = try incrementedSceneNumber(nextSceneNumber)
            candidate = "scene-\(nextSceneNumber)"
        }
        return candidate
    }

    private func nextSceneNumber(after entries: [ScenePersistenceIndexEntry]) throws -> Int {
        let maximum = entries.compactMap { entry -> Int? in
            guard let suffix = entry.sceneID.split(separator: "-").last,
                  entry.sceneID.hasPrefix("scene-") else {
                return nil
            }
            return Int(suffix)
        }.max() ?? 0
        return try incrementedSceneNumber(maximum)
    }

    private func incrementedSceneNumber(_ value: Int) throws -> Int {
        let (result, overflow) = value.addingReportingOverflow(1)
        guard !overflow else {
            throw ScenePersistenceError.atomicWriteFailed
        }
        return result
    }

    private func nextPersistenceOrder(_ orders: [Int]) throws -> Int {
        let maximum = orders.max() ?? -1
        let (result, overflow) = maximum.addingReportingOverflow(1)
        guard !overflow, result < Int.max else {
            throw ScenePersistenceError.invalidIndex
        }
        return result
    }

    public func scenes() -> [SavedScene] {
        storedScenes
    }

    public func cards() -> [SceneCardSnapshot] {
        storedScenes.map {
            SceneCardSnapshot(
                id: $0.id,
                name: $0.name,
                state: states[$0.id] ?? .stashed
            )
        }
    }

    public func state(sceneID: SceneID) -> SceneState? {
        states[sceneID]
    }

    public func report(sceneID: SceneID) -> SceneRestoreReport? {
        reports[sceneID]
    }

    public func currentSceneID() -> SceneID? {
        currentSceneIDValue
    }

    public func click(
        sceneID: SceneID,
        execute: @escaping SceneRestoreExecutor
    ) async -> SceneRoundTripOutcome {
        let previousState = states[sceneID]
        let previousReport = reports[sceneID]
        let previousCurrentSceneID = currentSceneIDValue
        let wasSwitchingScenes = previousCurrentSceneID != nil && previousCurrentSceneID != sceneID
        let outcome = await clickDetailed(sceneID: sceneID) { plan in
            SceneRestoreReport.assuming(
                plan: plan,
                succeeded: await execute(plan)
            )
        }
        if case .failed = outcome, !wasSwitchingScenes {
            // Preserve the P0-3 bool-executor contract atomically. P0-4
            // callers use clickDetailed to expose the Failed card state and
            // retry path.
            states[sceneID] = previousState
            reports[sceneID] = previousReport
            currentSceneIDValue = previousCurrentSceneID
        }
        if case let .failed(id) = outcome {
            return .operationFailed(sceneID: id)
        }
        return outcome
    }

    public func clickDetailed(
        sceneID: SceneID,
        execute: @escaping SceneDetailedRestoreExecutor
    ) async -> SceneRoundTripOutcome {
        guard !storedScenes.isEmpty else {
            return .emptyStore
        }
        guard let scene = storedScenes.first(where: { $0.id == sceneID }) else {
            return .sceneNotFound(sceneID: sceneID)
        }
        guard !isBusy else {
            return .busyRejected(sceneID: sceneID)
        }

        let currentState = states[sceneID] ?? .stashed
        let plan: SceneRestorePlan
        switch currentState {
        case .stashed, .partiallyRestored, .failed:
            plan = SceneRestorePlanner.displayPlan(for: scene)
        case .displayed:
            plan = SceneRestorePlanner.hidePlan(for: scene)
        case .preparing:
            return .busyRejected(sceneID: sceneID)
        }

        isBusy = true

        let previousCurrentSceneID = currentSceneIDValue
        if let currentSceneID = currentSceneIDValue,
           currentSceneID != sceneID,
           let currentScene = storedScenes.first(where: { $0.id == currentSceneID }) {
            states[currentSceneID] = .preparing
            let hidePlan = SceneRestorePlanner.hidePlan(for: currentScene)
            let hideReport = await execute(hidePlan)
            reports[currentSceneID] = hideReport
            states[currentSceneID] = hideReport.state

            guard hideReport.state == .stashed else {
                // A failed or partial hide leaves the active arrangement as
                // the safety anchor. The requested scene remains untouched.
                currentSceneIDValue = previousCurrentSceneID
                isBusy = false
                return outcome(for: hideReport)
            }
            currentSceneIDValue = nil
        }

        states[sceneID] = .preparing
        let report = await execute(plan)
        isBusy = false
        reports[sceneID] = report
        states[sceneID] = report.state
        currentSceneIDValue = report.currentSceneID
        return outcome(for: report)
    }

    private func outcome(for report: SceneRestoreReport) -> SceneRoundTripOutcome {
        switch report.state {
        case .displayed:
            return .displayed(sceneID: report.sceneID)
        case .stashed:
            return .stashed(sceneID: report.sceneID)
        case .partiallyRestored:
            return .partiallyRestored(sceneID: report.sceneID)
        case .failed:
            return .failed(sceneID: report.sceneID)
        case .preparing:
            return .failed(sceneID: report.sceneID)
        }
    }
}
