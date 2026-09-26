import AppKit
import SceneShelfAccessibility
import SceneShelfCore
import SceneShelfPresentation
import SwiftUI

@MainActor
final class ShelfViewModel: ObservableObject {
    private static let fixtureTargetFrame = AXFrame(
        x: 120,
        y: 140,
        width: 800,
        height: 600
    )

    @Published private(set) var cards: [SceneCardSnapshot] = []
    @Published private(set) var savedCards: [SceneCardSnapshot] = []
    @Published private(set) var savedCardFailureMessages: [SceneID: String] = [:]
    @Published private(set) var persistenceDiagnosticRows: [SceneShelfPersistenceDiagnosticRow] = []
    @Published private(set) var statusMessage = "クリックでシーンを切り替えます"
    @Published private(set) var accessibilityStatus = PermissionStatus(
        state: .denied,
        reason: "起動時に確認しています",
        allowsAXInspection: false
    )
    @Published private(set) var applicationCandidates: [AXApplicationCandidate] = []
    @Published private(set) var applicationCatalogMessage = "アプリ候補はまだ確認していません"
    @Published private(set) var selectedApplicationWindowIDs: Set<AXWindowIdentity> = []
    @Published var applicationCaptureName = "アプリ配置"
    @Published private(set) var fixtureWindows: [AXWindowSnapshot] = []
    @Published private(set) var selectedFixtureIDs: Set<AXWindowIdentity> = []
    @Published var captureName = SceneCaptureFlow.defaultName
    @Published private(set) var lastAXReport: AXOperationReport?
    @Published private(set) var lastSceneReport: SceneRestoreReport?
    @Published private(set) var accessibilityMessage = "権限なしではFixtureを操作しません"
    @Published private(set) var sceneManagementMessage = ""
    @Published var editingSceneID: SceneID? = nil
    @Published var renameDraft = ""
    @Published var isDeleteConfirmationPresented = false

    var canReloadPersistence: Bool {
        persistenceInitializationError == nil
    }

    private let coordinator: SceneCoordinator
    private let sceneStore: InMemorySceneStore
    private let accessibilityAdapter: any AXWindowAdapter
    private let persistenceInitializationError: ScenePersistenceError?

    private struct DefaultSceneStore {
        let store: InMemorySceneStore
        let initializationError: ScenePersistenceError?
    }

    private static func makeDefaultSceneStore() -> DefaultSceneStore {
        do {
            let persistence = try SceneShelfPersistence.applicationSupport()
            return DefaultSceneStore(
                store: InMemorySceneStore(persistence: persistence),
                initializationError: nil
            )
        } catch let error as ScenePersistenceError {
            return DefaultSceneStore(
                store: InMemorySceneStore(persistenceInitializationFailure: error),
                initializationError: error
            )
        } catch {
            let initializationError = ScenePersistenceError.applicationSupportUnavailable
            return DefaultSceneStore(
                store: InMemorySceneStore(persistenceInitializationFailure: initializationError),
                initializationError: initializationError
            )
        }
    }

    init(
        coordinator: SceneCoordinator,
        sceneStore: InMemorySceneStore? = nil,
        accessibilityAdapter: any AXWindowAdapter = AXSystemAdapter()
    ) {
        self.coordinator = coordinator
        if let sceneStore {
            self.sceneStore = sceneStore
            self.persistenceInitializationError = nil
        } else {
            let defaultSceneStore = Self.makeDefaultSceneStore()
            self.sceneStore = defaultSceneStore.store
            self.persistenceInitializationError = defaultSceneStore.initializationError
        }
        self.accessibilityAdapter = accessibilityAdapter
        Task { @MainActor [weak self] in
            await self?.loadPersistedScenes()
            await self?.refresh()
            await self?.refreshAccessibilityPermission()
        }
    }

    private func loadPersistedScenes(retry: Bool = false) async {
        if let persistenceInitializationError {
            let message = "\(persistenceInitializationError.japaneseLabel)。保存先を再生成できないため、設定を確認してアプリを再起動してください"
            persistenceDiagnosticRows = [
                SceneShelfPersistencePresentation.globalRow(
                    message: message
                )
            ]
            statusMessage = message
            accessibilityMessage = message
            return
        }
        do {
            let result = try await (retry
                ? sceneStore.retryLoadPersisted()
                : sceneStore.loadPersisted())
            persistenceDiagnosticRows = SceneShelfPersistencePresentation.rows(
                for: result.diagnostics
            )
            if !result.scenes.isEmpty, result.diagnostics.isEmpty {
                statusMessage = "保存済み配置を読み込みました"
            } else if !result.diagnostics.isEmpty {
                statusMessage = "保存済み配置の一部を読み込めませんでした"
            }
        } catch let error as SceneManagementError {
            // A reload during restore must not replace an existing diagnosis
            // with a transient busy message.
            statusMessage = error.japaneseLabel
        } catch let error as ScenePersistenceError {
            persistenceDiagnosticRows = [
                SceneShelfPersistencePresentation.globalRow(message: error.japaneseLabel)
            ]
            statusMessage = error.japaneseLabel
        } catch {
            persistenceDiagnosticRows = [
                SceneShelfPersistencePresentation.globalRow(
                    message: "保存済み配置の読み込みに失敗したため、保存を停止しました"
                )
            ]
            statusMessage = "保存済み配置の読み込みに失敗したため、保存を停止しました"
        }
    }

    func reloadPersistedScenes() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await loadPersistedScenes(retry: true)
            await refresh()
        }
    }

    func refresh() async {
        let snapshot = await coordinator.snapshot()
        cards = snapshot.cards
        savedCards = await sceneStore.cards()
    }

    func click(sceneID: SceneID) {
        if savedCards.contains(where: { $0.id == sceneID }) {
            clickSavedScene(sceneID: sceneID)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            statusMessage = "操作を準備中です"
            let operationTask = Task {
                await coordinator.click(sceneID: sceneID)
            }

            // The coordinator owns the state machine. Yield once so its
            // preparing snapshot can be observed before waiting for the
            // operation to complete, without duplicating state in the UI.
            await Task.yield()
            await refresh()

            let outcome = await operationTask.value
            switch outcome {
            case let .completed(_, state):
                statusMessage = state == .displayed ? "シーンを表示しました" : "シーンをしまいました"
            case .busyRejected:
                statusMessage = "別の操作を処理中です"
            case .sceneNotFound, .emptyShelf:
                statusMessage = "表示できるシーンがありません"
            }
            await refresh()
        }
    }

    func setFixtureSelection(_ identity: AXWindowIdentity, isSelected: Bool) {
        if isSelected {
            selectedFixtureIDs.insert(identity)
        } else {
            selectedFixtureIDs.remove(identity)
        }
    }

    func saveFixtureScene() {
        guard accessibilityStatus.state == .granted else {
            accessibilityMessage = "権限がないため配置を保存しません"
            return
        }
        guard !selectedFixtureIDs.isEmpty else {
            accessibilityMessage = "保存対象を1件以上選択してください"
            return
        }

        let selectedIDs = selectedFixtureIDs
        let name = captureName
        let store = sceneStore
        let adapter = accessibilityAdapter
        Task { @MainActor [weak self] in
            do {
                let preparation = try await AXSceneCapturePreparation.prepare(
                    adapter: adapter,
                    selectedIDs: selectedIDs
                )
                let candidates = preparation.candidates.compactMap(Self.sceneSnapshot(from:))
                let selected = Set(
                    preparation.selectedIDs.map { SceneWindowIdentity(from: $0) }
                )
                _ = try await store.save(
                    name: name,
                    candidates: candidates,
                    selectedIDs: selected
                )
                guard let self else { return }
                accessibilityMessage = "現在のFixture配置をローカルに保存しました"
                await refresh()
            } catch let error as AXSceneCaptureError {
                guard let self else { return }
                accessibilityMessage = SceneShelfAXPresentation.saveFailureMessage(for: error)
            } catch let error as SceneCaptureError {
                guard let self else { return }
                accessibilityMessage = error.japaneseLabel
            } catch let error as ScenePersistenceError {
                guard let self else { return }
                accessibilityMessage = error.japaneseLabel
            } catch let error as SceneManagementError {
                guard let self else { return }
                accessibilityMessage = SceneShelfManagementPresentation.message(for: error)
            } catch {
                guard let self else { return }
                accessibilityMessage = "配置を保存できませんでした"
            }
        }
    }

    func beginRename(sceneID: SceneID) {
        guard let card = savedCards.first(where: { $0.id == sceneID }) else {
            sceneManagementMessage = SceneManagementError.sceneNotFound(sceneID).japaneseLabel
            return
        }
        editingSceneID = sceneID
        renameDraft = card.name
    }

    func cancelRename() {
        editingSceneID = nil
        renameDraft = ""
    }

    func commitRename() {
        guard let sceneID = editingSceneID else { return }
        let name = renameDraft
        let store = sceneStore
        Task { @MainActor [weak self] in
            do {
                _ = try await store.rename(sceneID: sceneID, name: name)
                guard let self else { return }
                cancelRename()
                sceneManagementMessage = "配置名を変更しました"
                await refresh()
            } catch {
                guard let self else { return }
                sceneManagementMessage = SceneShelfManagementPresentation.message(for: error)
            }
        }
    }

    func overwriteSavedScene(sceneID: SceneID) {
        guard accessibilityStatus.state == .granted else {
            sceneManagementMessage = "権限がないため現在の配置を取得できません"
            return
        }
        let adapter = accessibilityAdapter
        let store = sceneStore
        Task { @MainActor [weak self] in
            guard let scene = await store.scene(sceneID: sceneID) else {
                guard let self else { return }
                sceneManagementMessage = SceneManagementError.sceneNotFound(sceneID).japaneseLabel
                return
            }
            guard scene.windows.allSatisfy({
                $0.identity.bundleIdentifier == SceneMatcher.fixtureBundleIdentifier
            }) else {
                guard let self else { return }
                sceneManagementMessage = SceneManagementError.applicationOverwriteUnsupported.japaneseLabel
                return
            }
            let discovery = await adapter.fixtureWindowResult()
            if let failureReason = discovery.failureReason {
                guard let self else { return }
                sceneManagementMessage = SceneShelfAXPresentation.overwriteFailureMessage(
                    for: failureReason
                )
                return
            }
            let candidates = discovery.windows.compactMap(Self.sceneSnapshot(from:))
            do {
                _ = try await store.overwrite(sceneID: sceneID, candidates: candidates)
                guard let self else { return }
                sceneManagementMessage = "現在の配置で上書きしました"
                await refresh()
            } catch {
                guard let self else { return }
                sceneManagementMessage = SceneShelfManagementPresentation.message(for: error)
            }
        }
    }

    func duplicateSavedScene(sceneID: SceneID) {
        let store = sceneStore
        Task { @MainActor [weak self] in
            do {
                _ = try await store.duplicate(sceneID: sceneID)
                guard let self else { return }
                sceneManagementMessage = "配置を複製しました"
                await refresh()
            } catch {
                guard let self else { return }
                sceneManagementMessage = SceneShelfManagementPresentation.message(for: error)
            }
        }
    }

    func moveSavedScene(sceneID: SceneID, direction: SceneMoveDirection) {
        let store = sceneStore
        Task { @MainActor [weak self] in
            do {
                _ = try await store.move(sceneID: sceneID, direction: direction)
                guard let self else { return }
                sceneManagementMessage = direction == .up ? "配置を上へ移動しました" : "配置を下へ移動しました"
                await refresh()
            } catch {
                guard let self else { return }
                sceneManagementMessage = SceneShelfManagementPresentation.message(for: error)
            }
        }
    }

    func requestDelete(sceneID: SceneID) {
        guard savedCards.contains(where: { $0.id == sceneID }) else {
            sceneManagementMessage = SceneManagementError.sceneNotFound(sceneID).japaneseLabel
            return
        }
        pendingDeleteSceneID = sceneID
        isDeleteConfirmationPresented = true
    }

    func cancelDelete() {
        pendingDeleteSceneID = nil
        isDeleteConfirmationPresented = false
    }

    func confirmDelete() {
        guard let sceneID = pendingDeleteSceneID else { return }
        pendingDeleteSceneID = nil
        isDeleteConfirmationPresented = false
        let store = sceneStore
        Task { @MainActor [weak self] in
            do {
                try await store.delete(sceneID: sceneID, confirmed: true)
                guard let self else { return }
                sceneManagementMessage = "配置を削除しました"
                await refresh()
            } catch {
                guard let self else { return }
                sceneManagementMessage = SceneShelfManagementPresentation.message(for: error)
                if SceneShelfManagementPresentation.shouldRefreshAfterDeleteFailure(error) {
                    await refresh()
                }
            }
        }
    }

    private var pendingDeleteSceneID: SceneID?

    func refreshAccessibilityPermission() async {
        let status = await accessibilityAdapter.permissionStatus()
        accessibilityStatus = status
        if status.state == .denied {
            fixtureWindows = []
            accessibilityMessage = "権限なしではFixtureの検出・操作を行いません"
            let catalogState = SceneShelfApplicationCatalogPresentation.catalogState(
                permission: status.state,
                result: nil
            )
            applicationCandidates = catalogState.candidates
            selectedApplicationWindowIDs =
                SceneShelfApplicationCatalogPresentation.selectedWindowIDs(
                    existing: selectedApplicationWindowIDs,
                    from: catalogState
                )
            applicationCatalogMessage = catalogState.message
        } else {
            accessibilityMessage = "許可済みです。対象Fixtureだけを検証できます"
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            accessibilityMessage = "設定画面を開けませんでした"
            return
        }
        if NSWorkspace.shared.open(url) {
            accessibilityMessage = "アクセシビリティ設定を開きました"
        } else {
            accessibilityMessage = "アクセシビリティ設定を開けませんでした"
        }
    }

    func recheckAccessibilityPermission() {
        Task { @MainActor [weak self] in
            await self?.refreshAccessibilityPermission()
        }
    }

    func detectFixture() {
        guard accessibilityStatus.state == .granted else {
            accessibilityMessage = "権限がないため検出を実行しません"
            return
        }
        let adapter = accessibilityAdapter
        Task { @MainActor [weak self] in
            let discovery = await adapter.fixtureWindowResult()
            guard let self else { return }
            fixtureWindows = discovery.windows
            selectedFixtureIDs = Set(discovery.windows.map(\.identity))
            accessibilityMessage = SceneShelfAXPresentation.discoveryMessage(for: discovery)
        }
    }

    /// Reads general application candidates without writing. Explicitly
    /// selected rows are handled by the separate save action below.
    func inspectApplicationCandidates() {
        let adapter = accessibilityAdapter
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard accessibilityStatus.state == .granted else {
                let catalogState = SceneShelfApplicationCatalogPresentation.catalogState(
                    permission: accessibilityStatus.state,
                    result: nil
                )
                applicationCandidates = catalogState.candidates
                selectedApplicationWindowIDs =
                    SceneShelfApplicationCatalogPresentation.selectedWindowIDs(
                        existing: selectedApplicationWindowIDs,
                        from: catalogState
                    )
                applicationCatalogMessage = catalogState.message
                return
            }
            let result = await adapter.applicationCatalog()
            let catalogState = SceneShelfApplicationCatalogPresentation.catalogState(
                permission: accessibilityStatus.state,
                result: result
            )
            applicationCandidates = catalogState.candidates
            selectedApplicationWindowIDs =
                SceneShelfApplicationCatalogPresentation.selectedWindowIDs(
                    existing: selectedApplicationWindowIDs,
                    from: catalogState
                )
            applicationCatalogMessage = catalogState.message
        }
    }

    func setApplicationSelection(_ identity: AXWindowIdentity, isSelected: Bool) {
        let selectableWindowIDs = Set(
            applicationCandidates.flatMap { candidate in
                SceneShelfApplicationCatalogPresentation.selectableWindowIDs(from: candidate)
            }
        )
        guard selectableWindowIDs.contains(identity) else {
            selectedApplicationWindowIDs.remove(identity)
            return
        }
        if isSelected {
            selectedApplicationWindowIDs.insert(identity)
        } else {
            selectedApplicationWindowIDs.remove(identity)
        }
    }

    func saveApplicationScene() {
        guard accessibilityStatus.state == .granted else {
            let catalogState = SceneShelfApplicationCatalogPresentation.catalogState(
                permission: accessibilityStatus.state,
                result: nil
            )
            applicationCandidates = catalogState.candidates
            selectedApplicationWindowIDs =
                SceneShelfApplicationCatalogPresentation.selectedWindowIDs(
                    existing: selectedApplicationWindowIDs,
                    from: catalogState
                )
            applicationCatalogMessage = catalogState.message
            return
        }
        guard !selectedApplicationWindowIDs.isEmpty else {
            applicationCatalogMessage = "保存対象を1件以上選択してください"
            return
        }

        let selectedIDs = selectedApplicationWindowIDs
        let name = applicationCaptureName
        let store = sceneStore
        let adapter = accessibilityAdapter
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await adapter.applicationCatalog()
            let catalogState = SceneShelfApplicationCatalogPresentation.catalogState(
                permission: accessibilityStatus.state,
                result: result
            )
            guard result.failureReason == nil else {
                applicationCandidates = catalogState.candidates
                selectedApplicationWindowIDs =
                    SceneShelfApplicationCatalogPresentation.selectedWindowIDs(
                        existing: selectedApplicationWindowIDs,
                        from: catalogState
                    )
                applicationCatalogMessage = catalogState.message
                return
            }

            do {
                let candidates = catalogState.candidates.flatMap(\.windows)
                let preparation = try AXSceneCapturePreparation.prepare(
                    candidates: candidates,
                    selectedIDs: selectedIDs
                )
                let sceneCandidates = preparation.selectedCandidates.compactMap(Self.sceneSnapshot(from:))
                let selected = Set(
                    preparation.selectedIDs.map { SceneWindowIdentity(from: $0) }
                )
                _ = try await store.save(
                    name: name,
                    candidates: sceneCandidates,
                    selectedIDs: selected
                )
                selectedApplicationWindowIDs = []
                applicationCatalogMessage = "選択したアプリ配置をローカルに保存しました"
                await refresh()
            } catch let error as AXSceneCaptureError {
                applicationCatalogMessage = SceneShelfAXPresentation.saveFailureMessage(for: error)
            } catch let error as SceneCaptureError {
                applicationCatalogMessage = error.japaneseLabel
            } catch let error as ScenePersistenceError {
                applicationCatalogMessage = error.japaneseLabel
            } catch let error as SceneManagementError {
                applicationCatalogMessage = SceneShelfManagementPresentation.message(for: error)
            } catch {
                applicationCatalogMessage = "アプリ配置を保存できませんでした"
            }
        }
    }

    func operateFixture() {
        guard accessibilityStatus.state == .granted else {
            accessibilityMessage = "権限がないため操作を実行しません"
            return
        }
        guard let window = fixtureWindows.first(where: {
            $0.identity.title == SceneShelfAXContract.fixtureMainWindowTitle
                && $0.identity.identifier == SceneShelfAXContract.fixtureMainWindowIdentifier
        }) else {
            accessibilityMessage = "Main Fixtureが見つからないため安全に中止しました"
            return
        }
        let request = AXOperationRequest(
            target: window.identity,
            frame: Self.fixtureTargetFrame,
            operations: [.move, .resize, .minimize]
        )
        let adapter = accessibilityAdapter
        Task { @MainActor [weak self] in
            let report = await adapter.perform(request)
            guard let self else { return }
            lastAXReport = report
            accessibilityMessage = report.succeeded
                ? "Fixtureへ安全な操作を完了しました"
                : (report.failureReason?.japaneseLabel ?? "Fixture操作を中止しました")
        }
    }

    private func clickSavedScene(sceneID: SceneID) {
        guard accessibilityStatus.state == .granted else {
            accessibilityMessage = "権限がないため保存済み配置を操作しません"
            return
        }

        let store = sceneStore
        let adapter = accessibilityAdapter
        Task { @MainActor [weak self] in
            guard let self else { return }
            statusMessage = "保存済み配置を操作中です"
            let operationTask = Task {
                await store.clickDetailed(sceneID: sceneID) { basePlan in
                    let plan = await Self.prepareRestorePlan(
                        basePlan,
                        adapter: adapter
                    )
                    let authorizationScope = AXAuthorizationScope(
                        allowedTargets: Set(
                            basePlan.instructions.map { Self.axIdentity(from: $0.target) }
                        )
                    )
                    var executedOutcomes: [SceneTargetRestoreOutcome] = []
                    for instruction in plan.instructions {
                        let request = Self.axRequest(
                            from: instruction,
                            authorizationScope: authorizationScope
                        )
                        let report = await adapter.perform(request)
                        let appliedOperations = report.appliedOperations.compactMap {
                            SceneWindowOperation(rawValue: $0.rawValue)
                        }
                        if report.succeeded {
                            executedOutcomes.append(
                                .succeeded(
                                    target: instruction.target,
                                    appliedOperations: appliedOperations
                                )
                            )
                        } else {
                            let reason = report.failureReason
                                .flatMap { SceneFailureReason(rawValue: $0.rawValue) }
                                ?? .operationFailed
                            executedOutcomes.append(
                                .failed(
                                    target: instruction.target,
                                    reason: reason,
                                    appliedOperations: appliedOperations
                                )
                            )
                        }
                    }
                    return SceneRestoreReport.from(
                        plan: plan,
                        executedOutcomes: executedOutcomes
                    )
                }
            }
            await Task.yield()
            await refresh()

            let outcome = await operationTask.value
            let reportSceneID = Self.reportSceneID(for: outcome, requestedSceneID: sceneID)
            let report = await store.report(sceneID: reportSceneID)
            lastSceneReport = report
            if let report {
                let message = SceneFailureMessageFormatter.format(report)
                if message.isEmpty {
                    savedCardFailureMessages.removeValue(forKey: reportSceneID)
                } else {
                    savedCardFailureMessages[reportSceneID] = message
                }
            }
            let switchWasAborted = reportSceneID != sceneID
            if switchWasAborted {
                statusMessage = "現在のシーンをしまえなかったため、切り替えを中止しました"
                accessibilityMessage = report.map(SceneFailureMessageFormatter.format)
                    ?? "現在のシーンをしまえなかったため、切り替えを中止しました"
            } else {
                switch outcome {
                case .displayed:
                    statusMessage = "保存済み配置を表示しました"
                case .stashed:
                    statusMessage = "保存済み配置をしまいました"
                case .partiallyRestored:
                    statusMessage = "保存済み配置を一部復元しました"
                    accessibilityMessage = report.map(SceneFailureMessageFormatter.format)
                        ?? "一部の対象を操作できませんでした"
                case .failed:
                    statusMessage = "保存済み配置の復元に失敗しました"
                    accessibilityMessage = report.map(SceneFailureMessageFormatter.format)
                        ?? "対象を操作できませんでした"
                case .busyRejected:
                    statusMessage = "別の配置操作を処理中です"
                case .operationFailed:
                    statusMessage = "保存済み配置の一部操作に失敗しました"
                case .sceneNotFound, .emptyStore:
                    statusMessage = "表示できる保存済み配置がありません"
                }
            }
            await refresh()
        }
    }

    nonisolated private static func reportSceneID(
        for outcome: SceneRoundTripOutcome,
        requestedSceneID: SceneID
    ) -> SceneID {
        switch outcome {
        case let .displayed(sceneID),
             let .stashed(sceneID),
             let .partiallyRestored(sceneID),
             let .failed(sceneID),
             let .operationFailed(sceneID):
            return sceneID
        case .busyRejected, .sceneNotFound, .emptyStore:
            return requestedSceneID
        }
    }

    nonisolated private static func sceneSnapshot(from window: AXWindowSnapshot) -> SceneWindowSnapshot? {
        guard let frame = window.frame else { return nil }
        return SceneWindowSnapshot(
            identity: SceneWindowIdentity(from: window.identity),
            frame: SceneFrame(from: frame),
            isMinimized: window.isMinimized
        )
    }

    nonisolated private static func axIdentity(from identity: SceneWindowIdentity) -> AXWindowIdentity {
        AXWindowIdentity(
            bundleIdentifier: identity.bundleIdentifier,
            processID: identity.processID,
            title: identity.title,
            identifier: identity.identifier
        )
    }

    nonisolated private static func axRequest(
        from instruction: SceneRestoreInstruction,
        authorizationScope: AXAuthorizationScope? = nil
    ) -> AXOperationRequest {
        AXOperationRequest(
            target: axIdentity(from: instruction.target),
            frame: instruction.frame.map(AXFrame.init(from:)),
            operations: instruction.operations.compactMap { AXOperation(rawValue: $0.rawValue) },
            authorizationScope: authorizationScope
        )
    }

    nonisolated private static func prepareRestorePlan(
        _ basePlan: SceneRestorePlan,
        adapter: any AXWindowAdapter
    ) async -> SceneRestorePlan {
        var candidates: [SceneWindowSnapshot] = []
        var preflightFailures = basePlan.preflightFailures
        var skippedTargets = Set<SceneWindowIdentity>()
        var resolvedApplicationKeys = Set<AXApplicationProcessIdentity>()

        for instruction in basePlan.instructions {
            let target = axIdentity(from: instruction.target)
            let applicationKey = AXApplicationProcessIdentity(
                bundleIdentifier: target.bundleIdentifier,
                processID: target.processID
            )
            guard resolvedApplicationKeys.insert(applicationKey).inserted else {
                continue
            }

            let discovery = await adapter.windowResult(for: target)
            if let failureReason = discovery.failureReason {
                let sceneReason = SceneFailureReason(rawValue: failureReason.rawValue)
                    ?? .operationFailed
                for relatedInstruction in basePlan.instructions where
                    relatedInstruction.target.bundleIdentifier == instruction.target.bundleIdentifier
                    && relatedInstruction.target.processID == instruction.target.processID {
                    skippedTargets.insert(relatedInstruction.target)
                    preflightFailures.append(
                        .failed(target: relatedInstruction.target, reason: sceneReason)
                    )
                }
                continue
            }
            candidates.append(contentsOf: discovery.windows.compactMap(sceneSnapshot(from:)))
        }

        let resolvablePlan = SceneRestorePlan(
            sceneID: basePlan.sceneID,
            action: basePlan.action,
            instructions: basePlan.instructions.filter {
                !skippedTargets.contains($0.target)
            },
            preflightFailures: preflightFailures
        )
        return SceneRestorePlanner.resolve(
            plan: resolvablePlan,
            candidates: candidates
        )
    }
}

private extension SceneWindowIdentity {
    init(from identity: AXWindowIdentity) {
        self.init(
            bundleIdentifier: identity.bundleIdentifier,
            processID: identity.processID,
            title: identity.title,
            identifier: identity.identifier
        )
    }
}

private extension SceneFrame {
    init(from frame: AXFrame) {
        self.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}

private extension AXFrame {
    init(from frame: SceneFrame) {
        self.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}

private extension SceneCaptureError {
    var japaneseLabel: String {
        switch self {
        case .emptySelection:
            return "保存対象を1件以上選択してください"
        case .unregisteredWindow:
            return "検出済みFixture以外は保存できません"
        case .duplicateWindow:
            return "同じFixtureウィンドウを重複して保存できません"
        }
    }
}

struct ShelfView: View {
    @ObservedObject var viewModel: ShelfViewModel

    var body: some View {
        ShelfScrollContainer {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scene Shelf")
                    .font(.headline)
                Spacer()
                Text("クリックで切替")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.cards.isEmpty {
                Text("シーンがありません")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("シーンがありません")
            } else {
                ForEach(viewModel.cards) { card in
                    Button {
                        viewModel.click(sceneID: card.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: card.state == .displayed ? "rectangle.inset.filled" : "rectangle")
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.name)
                                    .font(.body.weight(.medium))
                                Text(card.state.japaneseLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(card.name)・\(card.state.japaneseLabel)")
                    .accessibilityIdentifier("scene-card-\(card.id)")
                }
            }

            if !viewModel.savedCards.isEmpty {
                Divider()
                Text("保存済み配置")
                    .font(.subheadline.weight(.semibold))
                ForEach(viewModel.savedCards) { card in
                    if viewModel.editingSceneID == card.id {
                        HStack(spacing: 6) {
                            TextField("配置名", text: $viewModel.renameDraft)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("配置名を変更")
                                .accessibilityIdentifier("saved-scene-rename-field-\(card.id)")
                            Button("保存") {
                                viewModel.commitRename()
                            }
                            .accessibilityLabel("配置名を保存")
                            .accessibilityIdentifier("saved-scene-rename-save-\(card.id)")
                            Button("取消") {
                                viewModel.cancelRename()
                            }
                            .accessibilityLabel("配置名の変更を取消")
                            .accessibilityIdentifier("saved-scene-rename-cancel-\(card.id)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityIdentifier("saved-scene-rename-\(card.id)")
                    } else {
                        HStack(spacing: 4) {
                            Button {
                                viewModel.click(sceneID: card.id)
                            } label: {
                                SceneShelfCardPrimaryLabel {
                                    HStack(spacing: 10) {
                                        Image(systemName: card.state == .displayed ? "rectangle.inset.filled" : "rectangle")
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(card.name)
                                                .font(.body.weight(.medium))
                                            Text(card.state.japaneseLabel)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if let failureMessage = viewModel.savedCardFailureMessages[card.id] {
                                                Text(failureMessage)
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(card.name)・\(card.state.japaneseLabel)")
                            .accessibilityIdentifier("saved-scene-card-\(card.id)")

                            Menu {
                                Button("名前変更") {
                                    viewModel.beginRename(sceneID: card.id)
                                }
                                .accessibilityIdentifier("saved-scene-menu-rename-\(card.id)")
                                Button("現在の配置で上書き") {
                                    viewModel.overwriteSavedScene(sceneID: card.id)
                                }
                                .accessibilityIdentifier("saved-scene-menu-overwrite-\(card.id)")
                                Button("複製") {
                                    viewModel.duplicateSavedScene(sceneID: card.id)
                                }
                                .accessibilityIdentifier("saved-scene-menu-duplicate-\(card.id)")
                                Button("上へ") {
                                    viewModel.moveSavedScene(sceneID: card.id, direction: .up)
                                }
                                .accessibilityIdentifier("saved-scene-menu-up-\(card.id)")
                                Button("下へ") {
                                    viewModel.moveSavedScene(sceneID: card.id, direction: .down)
                                }
                                .accessibilityIdentifier("saved-scene-menu-down-\(card.id)")
                                Divider()
                                Button("削除", role: .destructive) {
                                    viewModel.requestDelete(sceneID: card.id)
                                }
                                .accessibilityIdentifier("saved-scene-menu-delete-\(card.id)")
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 28, height: 28)
                            }
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel("\(card.name)の管理メニュー")
                            .accessibilityIdentifier("saved-scene-menu-\(card.id)")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }

            if !viewModel.persistenceDiagnosticRows.isEmpty {
                SceneShelfPersistenceDiagnosticsView(
                    rows: viewModel.persistenceDiagnosticRows,
                    onReload: viewModel.reloadPersistedScenes,
                    canReload: viewModel.canReloadPersistence
                )
            }

            Divider()
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("shelf-status")

            if !viewModel.sceneManagementMessage.isEmpty {
                Text(viewModel.sceneManagementMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("scene-management-status")
            }

            Divider()
            GroupBox("一般アプリ候補（読み取り専用）") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(SceneShelfApplicationCatalogPresentation.readOnlyNotice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("アプリ候補を確認") {
                        viewModel.inspectApplicationCandidates()
                    }
                    .accessibilityLabel("読み取り専用のアプリ候補を確認")
                    .accessibilityIdentifier(
                        SceneShelfApplicationCatalogPresentation.inspectButtonIdentifier
                    )
                    Text(viewModel.applicationCatalogMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if viewModel.applicationCandidates.isEmpty {
                        Text("確認できるアプリ候補はありません")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.applicationCandidates) { candidate in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(
                                        SceneShelfApplicationCatalogPresentation.candidateLabel(
                                            for: candidate
                                        )
                                    )
                                    .font(.caption)
                                    ForEach(
                                        SceneShelfApplicationCatalogPresentation.windowRows(
                                            for: candidate
                                        )
                                    ) { row in
                                        if row.isSelectable {
                                            Toggle(isOn: Binding(
                                                get: {
                                                    viewModel.selectedApplicationWindowIDs.contains(
                                                        row.window.identity
                                                    )
                                                },
                                                set: {
                                                    viewModel.setApplicationSelection(
                                                        row.window.identity,
                                                        isSelected: $0
                                                    )
                                                }
                                            )) {
                                                Text(row.label)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            .toggleStyle(.checkbox)
                                            .accessibilityLabel(
                                                SceneShelfApplicationCatalogPresentation.selectionLabel(
                                                    for: row
                                                )
                                            )
                                            .accessibilityIdentifier(
                                                "application-selection-\(row.id)"
                                            )
                                        } else {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("一意に識別できないため保存対象にできません")
                                                    .font(.caption2.weight(.medium))
                                                    .foregroundStyle(.orange)
                                                Text(row.label)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            .accessibilityLabel(
                                                SceneShelfApplicationCatalogPresentation.selectionLabel(
                                                    for: row
                                                )
                                            )
                                            .accessibilityIdentifier(
                                                "application-selection-unavailable-\(row.id)"
                                            )
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                        .accessibilityIdentifier(
                            SceneShelfApplicationCatalogPresentation.listIdentifier
                        )

                        HStack(spacing: 8) {
                            TextField(
                                "アプリ配置名",
                                text: $viewModel.applicationCaptureName
                            )
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("保存するアプリ配置名")
                            .accessibilityIdentifier(
                                SceneShelfApplicationCatalogPresentation.nameFieldIdentifier
                            )
                            Button("選択したアプリ配置を保存") {
                                viewModel.saveApplicationScene()
                            }
                            .disabled(
                                viewModel.accessibilityStatus.state != .granted
                                    || viewModel.selectedApplicationWindowIDs.isEmpty
                            )
                            .accessibilityLabel("選択したアプリウィンドウの配置を保存")
                            .accessibilityIdentifier(
                                SceneShelfApplicationCatalogPresentation.saveButtonIdentifier
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("application-catalog-read-only")

            Divider()
            GroupBox("アクセシビリティ技術検証") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("対象: \(SceneShelfAXContract.fixtureBundleIdentifier)")
                        .font(.caption2)
                        .textSelection(.enabled)
                    Text("権限: \(viewModel.accessibilityStatus.state.japaneseLabel)")
                        .font(.caption)
                    Text(viewModel.accessibilityStatus.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(viewModel.accessibilityMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("設定を開く") {
                            viewModel.openAccessibilitySettings()
                        }
                        .accessibilityLabel("アクセシビリティ設定を開く")
                        .accessibilityIdentifier("accessibility-open-settings")

                        Button("権限を再確認") {
                            viewModel.recheckAccessibilityPermission()
                        }
                        .accessibilityLabel("アクセシビリティ権限を再確認")
                        .accessibilityIdentifier("accessibility-recheck-permission")

                        Button("Fixtureを検出") {
                            viewModel.detectFixture()
                        }
                        .disabled(viewModel.accessibilityStatus.state != .granted)
                        .accessibilityLabel("許可済みのFixtureを検出")
                        .accessibilityIdentifier("accessibility-detect-fixture")
                    }

                    Button("安全なFixture操作") {
                        viewModel.operateFixture()
                    }
                    .disabled(
                        viewModel.accessibilityStatus.state != .granted
                            || viewModel.fixtureWindows.isEmpty
                    )
                    .accessibilityLabel("検出したFixtureだけを安全に操作")
                    .accessibilityIdentifier("accessibility-operate-fixture")

                    ForEach(viewModel.fixtureWindows) { window in
                        Toggle(isOn: Binding(
                            get: { viewModel.selectedFixtureIDs.contains(window.identity) },
                            set: { viewModel.setFixtureSelection(window.identity, isSelected: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.identity.title)
                                    .font(.caption2)
                                Text("PID \(window.identity.processID)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(
                            "保存対象: \(window.identity.title)、PID \(window.identity.processID)"
                        )
                        .accessibilityIdentifier("fixture-selection-\(window.identity.id)")
                    }

                    HStack(spacing: 8) {
                        TextField("配置名", text: $viewModel.captureName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("保存する配置名")
                            .accessibilityIdentifier("fixture-scene-name")
                        Button("現在の配置を保存") {
                            viewModel.saveFixtureScene()
                        }
                        .disabled(
                            viewModel.accessibilityStatus.state != .granted
                                || viewModel.selectedFixtureIDs.isEmpty
                                || viewModel.fixtureWindows.isEmpty
                        )
                        .accessibilityLabel("選択したFixtureの現在の配置を保存")
                        .accessibilityIdentifier("fixture-save-scene")
                    }

                    if let report = viewModel.lastAXReport {
                        Text(
                            report.succeeded
                                ? "結果: \(report.appliedOperations.map(\.rawValue).joined(separator: ", "))"
                                : "結果: \(report.failureReason?.japaneseLabel ?? "失敗")"
                        )
                        .font(.caption2)
                        .accessibilityIdentifier("accessibility-operation-result")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("accessibility-verification")
            }
            .padding(16)
            .frame(width: SceneShelfLayout.viewportWidth)
        }
        .confirmationDialog(
            "この配置を削除しますか？",
            isPresented: $viewModel.isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                viewModel.confirmDelete()
            }
            Button("キャンセル", role: .cancel) {
                viewModel.cancelDelete()
            }
        } message: {
            Text("削除した配置は一覧から取り除かれます")
        }
    }
}

@MainActor
final class SceneShelfAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var shelfPanel: SceneShelfPanel?
    private var viewModel: ShelfViewModel?
    private var instanceLock: SceneShelfInstanceLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let persistence: SceneShelfPersistence
        do {
            persistence = try SceneShelfPersistence.applicationSupport()
            instanceLock = try SceneShelfInstanceLock.acquire(
                at: persistence.rootURL.appendingPathComponent(".instance.lock", isDirectory: false)
            )
        } catch let error as SceneShelfInstanceLockError {
            showStartupFailure(error.japaneseLabel)
            return
        } catch let error as ScenePersistenceError {
            showStartupFailure(error.japaneseLabel)
            return
        } catch {
            showStartupFailure("Scene Shelfの保存先を準備できないため起動できません")
            return
        }

        let coordinator = SceneCoordinator(
            scenes: FakeSceneFactory.defaultScenes,
            operation: { _, _ in
                // A deterministic delay keeps `準備中` and busy rejection
                // observable during the P0-1 manual click walkthrough.
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        )
        let viewModel = ShelfViewModel(
            coordinator: coordinator,
            sceneStore: InMemorySceneStore(persistence: persistence),
            accessibilityAdapter: AXSystemAdapter()
        )
        self.viewModel = viewModel

        let panel = SceneShelfPanel(
            contentRect: NSRect(origin: .zero, size: SceneShelfLayout.viewportSize)
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ShelfView(viewModel: viewModel))
        shelfPanel = panel

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Scene Shelf"
        statusItem.button?.toolTip = "Scene Shelfを表示"
        statusItem.button?.setAccessibilityLabel("Scene Shelfを表示")
        statusItem.button?.setAccessibilityIdentifier("scene-shelf-status-item")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleShelf)
        self.statusItem = statusItem
    }

    private func showStartupFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Scene Shelfを起動できません"
        alert.informativeText = message
        alert.addButton(withTitle: "終了")
        alert.runModal()
        NSApp.terminate(nil)
    }

    @objc private func toggleShelf() {
        guard let panel = shelfPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            position(panel: panel)
            panel.showShelf()
        }
    }

    private func position(panel: SceneShelfPanel) {
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return }
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.maxX - panelSize.width - 16,
            y: visibleFrame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

@main
@MainActor
struct SceneShelfMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = SceneShelfAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
