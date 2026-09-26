import Foundation

/// The only bundle that the P0-2 adapter is allowed to inspect or modify.
public enum SceneShelfAXContract {
    public static let fixtureBundleIdentifier = "com.fscoward.SceneShelfAXFixture"
    public static let sceneShelfBundleIdentifier = "com.fscoward.sceneshelf"
    public static let fixtureMainWindowIdentifier = "main"
    public static let fixtureMainWindowTitle = "Scene Shelf AX Fixture - Main"
}

public enum PermissionState: String, Equatable, Sendable {
    case denied
    case granted

    public var japaneseLabel: String {
        switch self {
        case .denied:
            return "未許可"
        case .granted:
            return "許可済み"
        }
    }
}

public struct PermissionStatus: Equatable, Sendable {
    public let state: PermissionState
    public let reason: String
    public let allowsAXInspection: Bool

    public init(state: PermissionState, reason: String, allowsAXInspection: Bool) {
        self.state = state
        self.reason = reason
        self.allowsAXInspection = allowsAXInspection
    }
}

public struct AXFrame: Equatable, Hashable, Sendable {
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

public struct AXWindowIdentity: Equatable, Hashable, Sendable, Identifiable {
    public let bundleIdentifier: String
    public let processID: Int32
    public let title: String
    public let identifier: String?

    public var id: String {
        let stablePart = identifier ?? title
        return bundleIdentifier + ":" + String(processID) + ":" + stablePart
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

public struct AXWindowSnapshot: Equatable, Hashable, Sendable, Identifiable {
    public let identity: AXWindowIdentity
    public let frame: AXFrame?
    public let isMinimized: Bool

    public var id: String { identity.id }

    public init(identity: AXWindowIdentity, frame: AXFrame?, isMinimized: Bool) {
        self.identity = identity
        self.frame = frame
        self.isMinimized = isMinimized
    }
}

/// A read-only process observation used by the general application catalog.
/// It deliberately contains only copied values; no AXUIElement or AppKit
/// object crosses the Accessibility boundary.
public struct AXApplicationProcessSnapshot: Equatable, Sendable {
    public let appName: String
    public let bundleIdentifier: String?
    public let processID: Int32
    public let windows: [AXWindowSnapshot]
    public let hasUserInterface: Bool
    public let isBackgroundOnly: Bool

    public init(
        appName: String,
        bundleIdentifier: String?,
        processID: Int32,
        windows: [AXWindowSnapshot],
        hasUserInterface: Bool,
        isBackgroundOnly: Bool
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.windows = windows
        self.hasUserInterface = hasUserInterface
        self.isBackgroundOnly = isBackgroundOnly
    }
}

/// A safe, grouped-by-process application candidate for the read-only UI.
public struct AXApplicationCandidate: Equatable, Sendable, Identifiable {
    public let appName: String
    public let bundleIdentifier: String
    public let processID: Int32
    public let windows: [AXWindowSnapshot]

    public var id: String {
        "\(bundleIdentifier):\(processID)"
    }

    public init(
        appName: String,
        bundleIdentifier: String,
        processID: Int32,
        windows: [AXWindowSnapshot]
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.windows = windows
    }
}

public struct AXApplicationProcessIdentity: Equatable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let processID: Int32

    public init(bundleIdentifier: String, processID: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
    }
}

public enum AXApplicationDiscovery {
    public static func uniqueProcessIdentities(
        from targets: [AXWindowIdentity]
    ) -> [AXApplicationProcessIdentity] {
        var seen = Set<AXApplicationProcessIdentity>()
        return targets.compactMap { target in
            let process = AXApplicationProcessIdentity(
                bundleIdentifier: target.bundleIdentifier,
                processID: target.processID
            )
            return seen.insert(process).inserted ? process : nil
        }
    }
}

public struct AXApplicationCatalogResult: Equatable, Sendable {
    public let candidates: [AXApplicationCandidate]
    public let failureReason: FailureReason?

    public var succeeded: Bool {
        failureReason == nil
    }

    public init(
        candidates: [AXApplicationCandidate],
        failureReason: FailureReason? = nil
    ) {
        self.candidates = candidates
        self.failureReason = failureReason
    }

    public static func success(_ candidates: [AXApplicationCandidate]) -> AXApplicationCatalogResult {
        AXApplicationCatalogResult(candidates: candidates)
    }

    public static func failure(_ reason: FailureReason) -> AXApplicationCatalogResult {
        AXApplicationCatalogResult(candidates: [], failureReason: reason)
    }
}

/// Pure normalization for a process observation list. This is the only place
/// where filtering rules for the P1-8 candidate surface are defined.
public enum AXApplicationCatalogNormalizer {
    public static func normalize(
        _ processes: [AXApplicationProcessSnapshot],
        excludingBundleIdentifier: String = SceneShelfAXContract.sceneShelfBundleIdentifier
    ) -> [AXApplicationCandidate] {
        processes.compactMap { process in
            guard let bundleIdentifier = process.bundleIdentifier,
                  !bundleIdentifier.isEmpty,
                  bundleIdentifier != excludingBundleIdentifier,
                  process.hasUserInterface,
                  !process.isBackgroundOnly,
                  !process.windows.isEmpty else {
                return nil
            }
            return AXApplicationCandidate(
                appName: process.appName,
                bundleIdentifier: bundleIdentifier,
                processID: process.processID,
                windows: process.windows
            )
        }
        .sorted {
            if $0.appName == $1.appName {
                if $0.bundleIdentifier == $1.bundleIdentifier {
                    return $0.processID < $1.processID
                }
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return $0.appName < $1.appName
        }
    }
}

public enum FailureReason: String, Error, Equatable, Sendable {
    case permissionDenied
    case applicationUnavailable
    case windowMissing
    case ambiguousMatch
    case windowChanged
    case pidReused
    case operationFailed
    case bundleNotAllowed
    case targetNotAuthorized

    public var japaneseLabel: String {
        switch self {
        case .permissionDenied:
            return "アクセシビリティ権限がありません"
        case .applicationUnavailable:
            return "Fixtureアプリが起動していません"
        case .windowMissing:
            return "対象ウィンドウが見つかりません"
        case .ambiguousMatch:
            return "対象ウィンドウを一意に特定できません"
        case .windowChanged:
            return "対象ウィンドウの識別情報が変わりました"
        case .pidReused:
            return "プロセスIDが変わりました"
        case .operationFailed:
            return "AX操作に失敗しました"
        case .bundleNotAllowed:
            return "許可されていないBundle IDです"
        case .targetNotAuthorized:
            return "保存対象として選択されていないため操作しません"
        }
    }
}

/// The value returned when the adapter tries to discover the fixture windows.
///
/// An empty window list is not sufficient to explain why discovery stopped:
/// the fixture can be missing, the process can be ambiguous, or Accessibility
/// can be denied. Keeping that reason beside the Sendable snapshots lets the
/// UI report the real boundary without exposing raw AX references.
public struct AXWindowDiscoveryResult: Equatable, Sendable {
    public let windows: [AXWindowSnapshot]
    public let failureReason: FailureReason?

    public var succeeded: Bool {
        failureReason == nil
    }

    public init(
        windows: [AXWindowSnapshot],
        failureReason: FailureReason? = nil
    ) {
        self.windows = windows
        self.failureReason = failureReason
    }

    public static func success(_ windows: [AXWindowSnapshot]) -> AXWindowDiscoveryResult {
        AXWindowDiscoveryResult(windows: windows)
    }

    public static func failure(_ reason: FailureReason) -> AXWindowDiscoveryResult {
        AXWindowDiscoveryResult(windows: [], failureReason: reason)
    }

    public var japaneseLabel: String {
        failureReason?.japaneseLabel ?? "Fixtureのウィンドウを検出しました"
    }
}

public enum AXOperation: String, Equatable, Sendable {
    case unminimize
    case move
    case resize
    case minimize
}

public struct AXOperationRequest: Equatable, Sendable {
    public let target: AXWindowIdentity
    public let frame: AXFrame?
    public let operations: [AXOperation]
    public let authorizationScope: AXAuthorizationScope?

    public init(
        target: AXWindowIdentity,
        frame: AXFrame? = nil,
        operations: [AXOperation] = [.move, .resize, .minimize],
        authorizationScope: AXAuthorizationScope? = nil
    ) {
        self.target = target
        self.frame = frame
        self.operations = operations
        self.authorizationScope = authorizationScope
    }
}

public struct AXOperationReport: Equatable, Sendable {
    public let target: AXWindowIdentity
    public let requestedOperations: [AXOperation]
    public let appliedOperations: [AXOperation]
    public let writesPerformed: Int
    public let failureReason: FailureReason?

    public var succeeded: Bool {
        failureReason == nil && appliedOperations == requestedOperations
    }

    public init(
        target: AXWindowIdentity,
        requestedOperations: [AXOperation],
        appliedOperations: [AXOperation] = [],
        writesPerformed: Int = 0,
        failureReason: FailureReason? = nil
    ) {
        self.target = target
        self.requestedOperations = requestedOperations
        self.appliedOperations = appliedOperations
        self.writesPerformed = writesPerformed
        self.failureReason = failureReason
    }
}

/// A Sendable, pure resolver. It deliberately knows nothing about AXUIElement.
public enum AXResolution: Equatable, Sendable {
    case unique(AXWindowSnapshot)
    case missing
    case ambiguous
    case windowChanged
    case pidReused
    case bundleNotAllowed

    public var failureReason: FailureReason? {
        switch self {
        case .unique:
            return nil
        case .missing:
            return .windowMissing
        case .ambiguous:
            return .ambiguousMatch
        case .windowChanged:
            return .windowChanged
        case .pidReused:
            return .pidReused
        case .bundleNotAllowed:
            return .bundleNotAllowed
        }
    }
}

public enum AXSafetyPolicy {
    public static func resolve(
        target: AXWindowIdentity,
        candidates: [AXWindowSnapshot]
    ) -> AXResolution {
        guard target.bundleIdentifier == SceneShelfAXContract.fixtureBundleIdentifier else {
            return .bundleNotAllowed
        }

        let allowedCandidates = candidates.filter {
            $0.identity.bundleIdentifier == SceneShelfAXContract.fixtureBundleIdentifier
        }

        let exactCandidates = allowedCandidates.filter {
            $0.identity.title == target.title && $0.identity.identifier == target.identifier
        }
        if exactCandidates.count > 1 {
            return .ambiguous
        }
        if let exact = exactCandidates.first {
            return exact.identity.processID == target.processID ? .unique(exact) : .pidReused
        }

        let sameHintDifferentPID = allowedCandidates.filter {
            $0.identity.title == target.title && $0.identity.identifier == target.identifier
        }
        if !sameHintDifferentPID.isEmpty {
            return .pidReused
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

/// The exact identities selected by a user are the only targets a scoped
/// generic operation may write. This value never contains raw AX references.
public struct AXAuthorizationScope: Equatable, Sendable {
    public let allowedTargets: Set<AXWindowIdentity>

    public init(allowedTargets: Set<AXWindowIdentity>) {
        self.allowedTargets = allowedTargets
    }
}

public enum AXAuthorizationDecision: Equatable, Sendable {
    case authorized
    case targetNotAuthorized
    case bundleNotAllowed

    public var failureReason: FailureReason? {
        switch self {
        case .authorized:
            return nil
        case .targetNotAuthorized:
            return .targetNotAuthorized
        case .bundleNotAllowed:
            return .bundleNotAllowed
        }
    }
}

/// Pure authorization for a write request originating from an explicit
/// catalog selection. Membership is exact: title, optional identifier, PID,
/// and bundle must all match the saved identity.
public enum AXAuthorizationPolicy {
    public static func authorize(
        target: AXWindowIdentity,
        scope: AXAuthorizationScope
    ) -> AXAuthorizationDecision {
        guard !target.bundleIdentifier.isEmpty,
              target.bundleIdentifier != SceneShelfAXContract.sceneShelfBundleIdentifier else {
            return .bundleNotAllowed
        }
        guard scope.allowedTargets.contains(target) else {
            return .targetNotAuthorized
        }
        return .authorized
    }
}

/// Pure matcher for a currently running non-Shelf application. A PID match is
/// mandatory; title plus identifier must then resolve to exactly one window.
public enum AXApplicationSafetyPolicy {
    public static func resolve(
        target: AXWindowIdentity,
        candidates: [AXWindowSnapshot]
    ) -> AXResolution {
        guard !target.bundleIdentifier.isEmpty,
              target.bundleIdentifier != SceneShelfAXContract.sceneShelfBundleIdentifier else {
            return .bundleNotAllowed
        }

        let sameBundle = candidates.filter {
            $0.identity.bundleIdentifier == target.bundleIdentifier
        }
        let sameProcess = sameBundle.filter {
            $0.identity.processID == target.processID
        }
        let exactHints = sameProcess.filter {
            $0.identity.title == target.title && $0.identity.identifier == target.identifier
        }
        if exactHints.count > 1 {
            return .ambiguous
        }
        if let exact = exactHints.first {
            return .unique(exact)
        }

        let sameHintDifferentPID = sameBundle.filter {
            $0.identity.title == target.title && $0.identity.identifier == target.identifier
        }
        if !sameHintDifferentPID.isEmpty {
            return .pidReused
        }

        if sameProcess.contains(where: { $0.identity.identifier == target.identifier }) {
            return .windowChanged
        }
        return .missing
    }
}

/// The UI and test runners exchange this protocol, never raw AX references.
public protocol AXWindowAdapter: Sendable {
    func permissionStatus() async -> PermissionStatus
    func fixtureWindows() async -> [AXWindowSnapshot]
    func fixtureWindowResult() async -> AXWindowDiscoveryResult
    func windowResult(for target: AXWindowIdentity) async -> AXWindowDiscoveryResult
    func applicationCatalog() async -> AXApplicationCatalogResult
    func perform(_ request: AXOperationRequest) async -> AXOperationReport
}

public extension AXWindowAdapter {
    /// Compatibility bridge for fake adapters and older callers that only
    /// provide the snapshot list. Live adapters override this to preserve the
    /// discovery failure reason that an empty list alone would lose.
    func fixtureWindowResult() async -> AXWindowDiscoveryResult {
        .success(await fixtureWindows())
    }

    /// Existing fixture-only fakes remain source-compatible. Live adapters
    /// override this boundary for exact bundle/PID application reads.
    func windowResult(for target: AXWindowIdentity) async -> AXWindowDiscoveryResult {
        if target.bundleIdentifier == SceneShelfAXContract.fixtureBundleIdentifier {
            return await fixtureWindowResult()
        }
        return .failure(.applicationUnavailable)
    }

    /// Existing fixture-only fakes remain source-compatible. The live adapter
    /// overrides this boundary with the read-only process enumeration.
    func applicationCatalog() async -> AXApplicationCatalogResult {
        .success([])
    }
}

public enum AXSceneCaptureError: Error, Equatable, Sendable {
    case emptySelection
    case discoveryFailed(FailureReason)
    case windowMissing(AXWindowIdentity)
    case ambiguousWindow(AXWindowIdentity)
    case frameUnavailable(AXWindowIdentity)

    public var japaneseLabel: String {
        switch self {
        case .emptySelection:
            return "保存対象を1件以上選択してください"
        case let .discoveryFailed(reason):
            return "保存対象を取得できないため、保存を中止しました: \(reason.japaneseLabel)"
        case let .windowMissing(identity):
            return "保存対象のウィンドウが見つからないため、保存を中止しました: \(identity.title)"
        case let .ambiguousWindow(identity):
            return "保存対象を一意に特定できないため、保存を中止しました: \(identity.title)"
        case let .frameUnavailable(identity):
            return "保存対象の位置を取得できないため、保存を中止しました: \(identity.title)"
        }
    }
}

public struct AXSceneCapturePreparation: Equatable, Sendable {
    public let candidates: [AXWindowSnapshot]
    public let selectedIDs: Set<AXWindowIdentity>

    /// The validated, selected-only projection to pass into scene storage.
    /// Keeping this separate from `candidates` lets a stale or duplicated
    /// unselected catalog row remain observable without making it part of the
    /// saved scene's duplicate-identity contract.
    public var selectedCandidates: [AXWindowSnapshot] {
        candidates.filter { selectedIDs.contains($0.identity) }
    }

    public init(
        candidates: [AXWindowSnapshot],
        selectedIDs: Set<AXWindowIdentity>
    ) {
        self.candidates = candidates
        self.selectedIDs = selectedIDs
    }

    public static func prepare(
        adapter: any AXWindowAdapter,
        selectedIDs: Set<AXWindowIdentity>
    ) async throws -> AXSceneCapturePreparation {
        let result = await adapter.fixtureWindowResult()
        if let failureReason = result.failureReason {
            throw AXSceneCaptureError.discoveryFailed(failureReason)
        }
        return try prepare(candidates: result.windows, selectedIDs: selectedIDs)
    }

    public static func prepare(
        candidates: [AXWindowSnapshot],
        selectedIDs: Set<AXWindowIdentity>
    ) throws -> AXSceneCapturePreparation {
        guard !selectedIDs.isEmpty else {
            throw AXSceneCaptureError.emptySelection
        }

        for selectedID in selectedIDs {
            let matches = candidates.filter { $0.identity == selectedID }
            guard matches.count == 1 else {
                if matches.isEmpty {
                    throw AXSceneCaptureError.windowMissing(selectedID)
                }
                throw AXSceneCaptureError.ambiguousWindow(selectedID)
            }
            guard matches[0].frame != nil else {
                throw AXSceneCaptureError.frameUnavailable(selectedID)
            }
        }

        return AXSceneCapturePreparation(
            candidates: candidates,
            selectedIDs: selectedIDs
        )
    }
}
