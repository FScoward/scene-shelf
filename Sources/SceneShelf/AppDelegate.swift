import AppKit
import SceneShelfAccessibility
import SceneShelfCore
import SceneShelfPresentation
import SwiftUI

private actor SceneIsolationOperationState {
    private var messages: [String] = []

    func recordCatalogFailure(_ reason: FailureReason) {
        messages.append("背景ウィンドウ一覧を取得できませんでした: \(reason.japaneseLabel)")
    }

    func recordIsolationFailure(
        target: AXWindowIdentity,
        reason: FailureReason
    ) {
        messages.append(
            "背景ウィンドウを退避できませんでした: \(target.title): \(reason.japaneseLabel)"
        )
    }

    func recordRestoreFailure(
        target: AXWindowIdentity,
        reason: SceneFailureReason
    ) {
        messages.append(
            "背景ウィンドウを復元できませんでした: \(target.title): \(reason.japaneseLabel)"
        )
    }

    func message() -> String {
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }.joined(separator: "\n")
    }
}

private final class ActiveSpaceObserverToken: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(
        center: NotificationCenter,
        handler: @Sendable @escaping (Notification) -> Void
    ) {
        self.center = center
        self.token = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main,
            using: handler
        )
    }

    deinit {
        center.removeObserver(token)
    }
}

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
    @Published private(set) var savedScenePreviews: [SceneID: SceneShelfPreview] = [:]
    @Published private(set) var savedSceneThumbnailData: [SceneID: Data] = [:]
    @Published private(set) var savedSceneThumbnailStates: [SceneID: SceneThumbnailState] = [:]
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
    @Published private(set) var workspaceContextMessage = ""
    @Published private(set) var workspaceScopeMessage = ""
    @Published private(set) var currentWorkspaceContext: WorkspaceContext?
    @Published var editingSceneID: SceneID? = nil
    @Published var renameDraft = ""
    @Published var isDeleteConfirmationPresented = false

    var canReloadPersistence: Bool {
        persistenceInitializationError == nil
    }

    private let coordinator: SceneCoordinator
    private let sceneStore: InMemorySceneStore
    private let accessibilityAdapter: any AXWindowAdapter
    private let backgroundWindowCoordinator = AXWindowIsolationCoordinator()
    private let persistenceInitializationError: ScenePersistenceError?
    private let thumbnailCache: SceneThumbnailCache?
    private let thumbnailCaptureService: any SceneThumbnailCapturing
    private let workspaceContextProvider: any WorkspaceContextProviding
    private var activeSpaceObserver: ActiveSpaceObserverToken?

    private struct DefaultSceneStore {
        let store: InMemorySceneStore
        let initializationError: ScenePersistenceError?
    }

    private static func makeDefaultSceneStore() -> DefaultSceneStore {
        do {
            let persistence = try SceneShelfPersistence.applicationSupport()
            return DefaultSceneStore(
                store: InMemorySceneStore(
                    persistence: persistence,
                    workspaceContextProvider: SkyLightWorkspaceContextProvider(),
                    windowMembershipProvider: SkyLightWorkspaceWindowMembershipProvider()
                ),
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

    private static func makeDefaultThumbnailCache() -> SceneThumbnailCache? {
        guard let persistence = try? SceneShelfPersistence.applicationSupport() else {
            return nil
        }
        return SceneThumbnailCache(rootURL: persistence.rootURL)
    }

    init(
        coordinator: SceneCoordinator,
        sceneStore: InMemorySceneStore? = nil,
        accessibilityAdapter: any AXWindowAdapter = AXSystemAdapter(),
        thumbnailCache: SceneThumbnailCache? = nil,
        thumbnailCaptureService: any SceneThumbnailCapturing = ScreenCaptureKitThumbnailCaptureService(),
        workspaceContextProvider: any WorkspaceContextProviding = SkyLightWorkspaceContextProvider()
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
        self.thumbnailCache = thumbnailCache ?? Self.makeDefaultThumbnailCache()
        self.thumbnailCaptureService = thumbnailCaptureService
        self.workspaceContextProvider = workspaceContextProvider
        activeSpaceObserver = ActiveSpaceObserverToken(
            center: NSWorkspace.shared.notificationCenter
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        Task { @MainActor [weak self] in
            await self?.loadPersistedScenes()
            await self?.refresh()
            await self?.refreshAccessibilityPermission()
        }
    }

    deinit {
        activeSpaceObserver = nil
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
        let scenes = await sceneStore.scenes()
        let currentContext: WorkspaceContext
        do {
            currentContext = try workspaceContextProvider.currentWorkspaceContext()
            workspaceContextMessage = ""
        } catch let error as WorkspaceContextError {
            currentWorkspaceContext = nil
            workspaceContextMessage = error.japaneseLabel
            workspaceScopeMessage = ""
            savedCards = []
            savedScenePreviews = [:]
            savedSceneThumbnailData = [:]
            savedSceneThumbnailStates = [:]
            savedCardFailureMessages = [:]
            return
        } catch {
            currentWorkspaceContext = nil
            workspaceContextMessage = WorkspaceContextError.currentContextUnavailable.japaneseLabel
            workspaceScopeMessage = ""
            savedCards = []
            savedScenePreviews = [:]
            savedSceneThumbnailData = [:]
            savedSceneThumbnailStates = [:]
            savedCardFailureMessages = [:]
            return
        }
        currentWorkspaceContext = currentContext
        let scopedScenes = scenes.filter {
            guard let context = $0.workspaceContext else { return false }
            return context.sameScope(as: currentContext)
        }
        let scopedSceneIDs = Set(scopedScenes.map(\.id))
        savedCardFailureMessages = savedCardFailureMessages.filter {
            scopedSceneIDs.contains($0.key)
        }
        savedCards = await sceneStore.cards(workspaceContext: currentContext)
        workspaceScopeMessage = scopedScenes.isEmpty
            ? "このSpaceに保存済み配置はありません"
            : ""
        savedScenePreviews = SceneShelfPreviewPresentation.previews(for: scopedScenes)
        var thumbnailData: [SceneID: Data] = [:]
        var thumbnailStates: [SceneID: SceneThumbnailState] = [:]
        for scene in scopedScenes {
            if let thumbnailCache {
                do {
                    if let data = try thumbnailCache.read(sceneID: scene.id) {
                        thumbnailData[scene.id] = data
                        thumbnailStates[scene.id] = .available
                        continue
                    }
                } catch {
                    // A corrupt cache is a derived-data problem; keep the
                    // saved scene usable with its deterministic layout.
                }
            }
            thumbnailStates[scene.id] = .fallback
        }
        savedSceneThumbnailData = thumbnailData
        savedSceneThumbnailStates = thumbnailStates
    }

    @discardableResult
    private func captureThumbnail(for scene: SavedScene) async -> Bool {
        guard let thumbnailCache else {
            savedSceneThumbnailStates[scene.id] = .failed("配置プレビューの保存先を準備できませんでした")
            return false
        }
        savedSceneThumbnailStates[scene.id] = .loading
        do {
            let data = try await thumbnailCaptureService.capture(scene: scene)
            try thumbnailCache.write(data, sceneID: scene.id)
            savedSceneThumbnailData[scene.id] = data
            savedSceneThumbnailStates[scene.id] = .available
            return true
        } catch let error as SceneThumbnailCaptureError {
            savedSceneThumbnailStates[scene.id] = .failed(error.japaneseLabel)
            sceneManagementMessage = error.japaneseLabel
            return false
        } catch let error as SceneThumbnailCacheError {
            savedSceneThumbnailStates[scene.id] = .failed(error.japaneseLabel)
            sceneManagementMessage = error.japaneseLabel
            return false
        } catch {
            savedSceneThumbnailStates[scene.id] = .failed("配置プレビューを更新できませんでした")
            sceneManagementMessage = "配置プレビューを更新できませんでした"
            return false
        }
    }

    func updateSavedSceneThumbnail(sceneID: SceneID) {
        let store = sceneStore
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let scene = await store.scene(sceneID: sceneID) else {
                sceneManagementMessage = SceneManagementError.sceneNotFound(sceneID).japaneseLabel
                return
            }
            await captureThumbnail(for: scene)
            if savedSceneThumbnailStates[sceneID] == .available {
                sceneManagementMessage = "配置プレビューを更新しました"
            }
        }
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
                let savedScene = try await store.save(
                    name: name,
                    candidates: candidates,
                    selectedIDs: selected
                )
                guard let self else { return }
                await captureThumbnail(for: savedScene)
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
            } catch let error as WorkspaceContextError {
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
                let overwritten = try await store.overwrite(sceneID: sceneID, candidates: candidates)
                guard let self else { return }
                let previewCaptured = await captureThumbnail(for: overwritten)
                if previewCaptured {
                    sceneManagementMessage = "現在の配置で上書きしました"
                }
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
                let duplicate = try await store.duplicate(sceneID: sceneID)
                guard let self else { return }
                if let thumbnailCache {
                    do {
                        try thumbnailCache.copy(from: sceneID, to: duplicate.id)
                        if let data = try thumbnailCache.read(sceneID: duplicate.id) {
                            savedSceneThumbnailData[duplicate.id] = data
                            savedSceneThumbnailStates[duplicate.id] = .available
                        }
                    } catch {
                        savedSceneThumbnailStates[duplicate.id] = .fallback
                    }
                }
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
                try? thumbnailCache?.remove(sceneID: sceneID)
                savedSceneThumbnailData.removeValue(forKey: sceneID)
                savedSceneThumbnailStates.removeValue(forKey: sceneID)
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
                let savedScene = try await store.save(
                    name: name,
                    candidates: sceneCandidates,
                    selectedIDs: selected
                )
                await captureThumbnail(for: savedScene)
                selectedApplicationWindowIDs = []
                applicationCatalogMessage = "選択したアプリ配置をローカルに保存しました"
                await refresh()
            } catch let error as AXSceneCaptureError {
                applicationCatalogMessage = SceneShelfAXPresentation.saveFailureMessage(for: error)
            } catch let error as SceneCaptureError {
                applicationCatalogMessage = error.japaneseLabel
            } catch let error as ScenePersistenceError {
                applicationCatalogMessage = error.japaneseLabel
            } catch let error as WorkspaceContextError {
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
        let backgroundWindowCoordinator = self.backgroundWindowCoordinator
        Task { @MainActor [weak self] in
            guard let self else { return }
            statusMessage = "保存済み配置を操作中です"
            let operationState = SceneIsolationOperationState()
            let operationTask = Task {
                await store.clickDetailed(sceneID: sceneID) { basePlan in
                    if let failureReason = await store.workspaceScopeFailure(
                        sceneID: basePlan.sceneID
                    ) {
                        return Self.restoreReportBlockingRemaining(
                            plan: basePlan,
                            reason: failureReason
                        )
                    }
                    if basePlan.action == .display {
                        let isolationResult = await backgroundWindowCoordinator.isolateBeforeDisplay(
                            excluding: Set(
                                basePlan.instructions.map { Self.axIdentity(from: $0.target) }
                            ),
                            adapter: adapter
                        )
                        if let failureReason = isolationResult.catalogFailure {
                            await operationState.recordCatalogFailure(failureReason)
                        }
                        for failure in isolationResult.failures {
                            await operationState.recordIsolationFailure(
                                target: failure.target,
                                reason: failure.reason
                            )
                        }
                        if let failureReason = await store.workspaceScopeFailure(
                            sceneID: basePlan.sceneID
                        ) {
                            return Self.restoreReportBlockingRemaining(
                                plan: basePlan,
                                reason: failureReason
                            )
                        }
                    }
                    let plan = await Self.prepareRestorePlan(
                        basePlan,
                        adapter: adapter
                    )
                    if let failureReason = await store.workspaceScopeFailure(
                        sceneID: basePlan.sceneID
                    ) {
                        return Self.restoreReportBlockingRemaining(
                            plan: plan,
                            reason: failureReason
                        )
                    }
                    let authorizationScope = AXAuthorizationScope(
                        allowedTargets: Set(
                            basePlan.instructions.map { Self.axIdentity(from: $0.target) }
                        )
                    )
                    var executedOutcomes: [SceneTargetRestoreOutcome] = []
                    for (index, instruction) in plan.instructions.enumerated() {
                        let request = Self.axRequest(
                            from: instruction,
                            authorizationScope: authorizationScope
                        )
                        if let failureReason = await store.workspaceScopeFailure(
                            sceneID: basePlan.sceneID
                        ) {
                            executedOutcomes.append(contentsOf: plan.instructions[index...].map {
                                .failed(target: $0.target, reason: failureReason)
                            })
                            break
                        }
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
            if SceneBackgroundRestorePolicy.shouldRestore(after: report),
               await store.currentSceneID() == nil {
                await Self.restoreBackgroundWindows(
                    coordinator: backgroundWindowCoordinator,
                    adapter: adapter,
                    operationState: operationState
                )
            }
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
            let isolationMessage = await operationState.message()
            if !isolationMessage.isEmpty {
                statusMessage += "。\(isolationMessage)"
                let reportMessage = report.map(SceneFailureMessageFormatter.format) ?? ""
                accessibilityMessage = [reportMessage, isolationMessage]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
            await refresh()
        }
    }

    nonisolated private static func restoreBackgroundWindows(
        coordinator: AXWindowIsolationCoordinator,
        adapter: any AXWindowAdapter,
        operationState: SceneIsolationOperationState
    ) async {
        let failures = await coordinator.restoreBackground(adapter: adapter)
        for failure in failures {
            await operationState.recordRestoreFailure(
                target: failure.target,
                reason: SceneFailureReason(rawValue: failure.reason.rawValue) ?? .operationFailed
            )
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

    nonisolated private static func restoreReportBlockingRemaining(
        plan: SceneRestorePlan,
        reason: SceneFailureReason,
        executedOutcomes: [SceneTargetRestoreOutcome] = []
    ) -> SceneRestoreReport {
        let executedTargets = Set(executedOutcomes.map(\.target))
        let blockedOutcomes: [SceneTargetRestoreOutcome] = plan.instructions.compactMap { instruction in
            guard !executedTargets.contains(instruction.target) else { return nil }
            return SceneTargetRestoreOutcome.failed(
                target: instruction.target,
                reason: reason
            )
        }
        return SceneRestoreReport.from(
            plan: plan,
            executedOutcomes: executedOutcomes + blockedOutcomes
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
        case .workspaceContextUnavailable:
            return "Space情報を取得できないため保存できません"
        case .windowOutsideCurrentSpace:
            return "現在のSpace外のウィンドウは保存できません"
        case .windowInMultipleSpaces:
            return "複数Spaceに属するウィンドウは保存できません"
        case .windowSpaceMissing:
            return "対象ウィンドウのSpace情報を取得できません"
        }
    }
}

struct ShelfView: View {
    @ObservedObject var viewModel: ShelfViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .sceneShelfGlassSurface(.header)

            if !viewModel.workspaceContextMessage.isEmpty {
                Text(viewModel.workspaceContextMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspace-context-error")
            } else if !viewModel.savedCards.isEmpty {
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
                                    HStack(spacing: 12) {
                                        SceneShelfPreviewThumbnail(
                                            preview: viewModel.savedScenePreviews[card.id]
                                                ?? SceneShelfPreview(sceneID: card.id, windows: []),
                                            isDisplayed: card.state == .displayed,
                                            thumbnailData: viewModel.savedSceneThumbnailData[card.id]
                                        )
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
                                        Image(systemName: card.state == .displayed
                                            ? "checkmark.circle.fill"
                                            : "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(card.state == .displayed
                                                ? Color.accentColor
                                                : Color.secondary)
                                    }
                                }
                                .sceneShelfGlassSurface(.card)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            card.state == .displayed
                                                ? Color.accentColor.opacity(0.9)
                                                : .clear,
                                            lineWidth: card.state == .displayed ? 1.5 : 0
                                        )
                                        .allowsHitTesting(false)
                                )
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
                                Button("プレビューを更新") {
                                    viewModel.updateSavedSceneThumbnail(sceneID: card.id)
                                }
                                .accessibilityIdentifier("saved-scene-menu-refresh-thumbnail-\(card.id)")
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
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.18),
                            value: card.state
                        )
                    }
                }
            } else if !viewModel.workspaceScopeMessage.isEmpty {
                Divider()
                Text("保存済み配置")
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.workspaceScopeMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspace-scope-empty")
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
                    .sceneShelfGlassPrimaryButtonStyle()
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
                            .sceneShelfGlassPrimaryButtonStyle()
                            .accessibilityLabel("選択したアプリウィンドウの配置を保存")
                            .accessibilityIdentifier(
                                SceneShelfApplicationCatalogPresentation.saveButtonIdentifier
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sceneShelfReadableContentSurface()
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
                    .sceneShelfGlassPrimaryButtonStyle()
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
                        .sceneShelfGlassPrimaryButtonStyle()
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
            .sceneShelfReadableContentSurface()
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

        // The product shelf is populated exclusively from persisted scenes.
        // FakeSceneFactory remains available to the core test runners only.
        let coordinator = SceneCoordinator(scenes: [])
        let viewModel = ShelfViewModel(
            coordinator: coordinator,
            sceneStore: InMemorySceneStore(
                persistence: persistence,
                workspaceContextProvider: SkyLightWorkspaceContextProvider(),
                windowMembershipProvider: SkyLightWorkspaceWindowMembershipProvider()
            ),
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
