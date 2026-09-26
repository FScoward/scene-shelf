import Foundation
import SceneShelfAccessibility

/// Japanese, user-facing strings for the read-only application catalog.
/// No save or restore action is exposed from this presentation boundary.
public enum SceneShelfApplicationCatalogPresentation {
    public static let inspectButtonIdentifier = "accessibility-inspect-applications"
    public static let listIdentifier = "application-candidate-list"
    public static let readOnlyNotice = "読み取り専用の候補確認です。window title/PIDをこの端末内で読み取り表示するだけで、保存・復元には接続していません。"
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

    public static func windowRows(
        for candidate: AXApplicationCandidate
    ) -> [SceneShelfApplicationWindowRow] {
        candidate.windows.enumerated().map { index, window in
            SceneShelfApplicationWindowRow(
                id: "\(candidate.id)-window-\(index)",
                window: window,
                label: windowLabel(for: window)
            )
        }
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

    public init(id: String, window: AXWindowSnapshot, label: String) {
        self.id = id
        self.window = window
        self.label = label
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
