import Foundation
import SceneShelfAccessibility

/// Japanese, user-facing strings for the application catalog.
/// Catalog observation remains read-only; the explicit selection/save action is wired by the Shelf view model.
public enum SceneShelfApplicationCatalogPresentation {
    public static let inspectButtonIdentifier = "accessibility-inspect-applications"
    public static let listIdentifier = "application-candidate-list"
    public static let saveButtonIdentifier = "application-save-scene"
    public static let nameFieldIdentifier = "application-scene-name"
    public static let readOnlyNotice = "候補の確認自体は読み取り専用です。window title/PIDをこの端末内で読み取り表示します。保存・復元は選択したwindowだけを明示操作します。"
    public static let permissionRevokedMessage = "アクセシビリティ権限が取り消されたため、アプリ候補を消去しました"

    public static func candidateLabel(for candidate: AXApplicationCandidate) -> String {
        "アプリ: \(candidate.appName) / Bundle ID: \(candidate.bundleIdentifier) / PID \(candidate.processID)"
    }

    public static func windowLabel(for window: AXWindowSnapshot) -> String {
        let identifier = window.identity.identifier ?? "識別子なし"
        let frame: String
        if let value = window.frame {
            frame = String(
                format: "frame: %.0f,%.0f %.0f×%.0f",
                value.x,
                value.y,
                value.width,
                value.height
            )
        } else {
            frame = "frame: 取得できません"
        }
        let minimized = window.isMinimized ? "最小化" : "表示中"
        return "ウィンドウ: \(window.identity.title) / identifier: \(identifier) / \(frame) / 状態: \(minimized)"
    }

    public static func selectionLabel(for row: SceneShelfApplicationWindowRow) -> String {
        if row.isSelectable {
            return "保存対象: \(row.label)"
        }
        return "一意に識別できないため保存対象にできません: \(row.label)"
    }

    public static func windowRows(
        for candidate: AXApplicationCandidate
    ) -> [SceneShelfApplicationWindowRow] {
        let identityCounts = Dictionary(
            candidate.windows.map { ($0.identity, 1) },
            uniquingKeysWith: +
        )
        return candidate.windows.enumerated().map { index, window in
            SceneShelfApplicationWindowRow(
                id: "\(candidate.id)-window-\(index)",
                window: window,
                label: windowLabel(for: window),
                isSelectable: identityCounts[window.identity] == 1
            )
        }
    }

    public static func selectableWindowIDs(
        from candidate: AXApplicationCandidate
    ) -> Set<AXWindowIdentity> {
        Set(
            windowRows(for: candidate)
                .filter(\.isSelectable)
                .map(\.window.identity)
        )
    }

    public static func selectedWindowIDs(
        existing: Set<AXWindowIdentity>,
        from state: SceneShelfApplicationCatalogState
    ) -> Set<AXWindowIdentity> {
        let selectable = Set(
            state.candidates.flatMap { candidate in
                selectableWindowIDs(from: candidate)
            }
        )
        return existing.intersection(selectable)
    }

    public static func catalogState(
        permission: PermissionState,
        result: AXApplicationCatalogResult?
    ) -> SceneShelfApplicationCatalogState {
        guard permission == .granted else {
            return SceneShelfApplicationCatalogState(
                candidates: [],
                message: permissionRevokedMessage
            )
        }
        guard let result else {
            return SceneShelfApplicationCatalogState(
                candidates: [],
                message: "アプリ候補はまだ確認していません"
            )
        }
        if result.failureReason != nil {
            return SceneShelfApplicationCatalogState(
                candidates: [],
                message: resultMessage(for: result)
            )
        }
        return SceneShelfApplicationCatalogState(
            candidates: result.candidates,
            message: resultMessage(for: result)
        )
    }

    public static func resultMessage(for result: AXApplicationCatalogResult) -> String {
        if let failureReason = result.failureReason {
            return "アプリ候補を確認できません: \(failureReason.japaneseLabel)"
        }
        return "アプリ候補を\(result.candidates.count)件確認しました"
    }
}

public struct SceneShelfApplicationWindowRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let window: AXWindowSnapshot
    public let label: String
    public let isSelectable: Bool

    public init(
        id: String,
        window: AXWindowSnapshot,
        label: String,
        isSelectable: Bool = true
    ) {
        self.id = id
        self.window = window
        self.label = label
        self.isSelectable = isSelectable
    }
}

public struct SceneShelfApplicationCatalogState: Equatable, Sendable {
    public let candidates: [AXApplicationCandidate]
    public let message: String

    public init(candidates: [AXApplicationCandidate], message: String) {
        self.candidates = candidates
        self.message = message
    }
}
