import SceneShelfCore
import SwiftUI

public struct SceneShelfPersistenceDiagnosticRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let sceneID: SceneID
    public let message: String
    public let path: String

    public init(id: String, sceneID: SceneID, message: String, path: String) {
        self.id = id
        self.sceneID = sceneID
        self.message = message
        self.path = path
    }
}

public enum SceneShelfPersistencePresentation {
    public static let reloadButtonIdentifier = "persistence-reload"

    public static func rows(
        for diagnostics: [ScenePersistenceDiagnostic]
    ) -> [SceneShelfPersistenceDiagnosticRow] {
        diagnostics.map { diagnostic in
            SceneShelfPersistenceDiagnosticRow(
                id: "\(diagnostic.sceneID)|\(diagnostic.kind.rawValue)|\(diagnostic.path)",
                sceneID: diagnostic.sceneID,
                message: reason(for: diagnostic.kind),
                path: diagnostic.path
            )
        }
    }

    public static func globalRow(
        message: String
    ) -> SceneShelfPersistenceDiagnosticRow {
        SceneShelfPersistenceDiagnosticRow(
            id: "persistence-global",
            sceneID: "一覧全体",
            message: message,
            path: ""
        )
    }

    public static func rowLabel(
        for row: SceneShelfPersistenceDiagnosticRow
    ) -> String {
        "対象: \(row.sceneID): \(row.message)"
    }

    private static func reason(
        for kind: ScenePersistenceDiagnosticKind
    ) -> String {
        switch kind {
        case .missingRevision:
            return "保存ファイルが見つかりません"
        case .corruptRevision:
            return "保存ファイルが壊れています"
        case .unsupportedRevisionVersion:
            return "保存ファイルのschema versionに対応していません"
        case .invalidRevision:
            return "保存ファイルの内容を検証できません"
        case .orphanRevision:
            return "一覧に紐づかない保存履歴が残っています"
        }
    }
}

public struct SceneShelfPersistenceDiagnosticsView: View {
    private let rows: [SceneShelfPersistenceDiagnosticRow]
    private let onReload: () -> Void
    private let canReload: Bool

    public init(
        rows: [SceneShelfPersistenceDiagnosticRow],
        onReload: @escaping () -> Void,
        canReload: Bool = true
    ) {
        self.rows = rows
        self.onReload = onReload
        self.canReload = canReload
    }

    public var body: some View {
        GroupBox("保存診断") {
            VStack(alignment: .leading, spacing: 8) {
                Text("読み込めない保存済み配置があります。元ファイルは変更していません。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SceneShelfPersistencePresentation.rowLabel(for: row))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("persistence-diagnostic-\(row.id)")
                        if !row.path.isEmpty {
                            Text(row.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }

                if canReload {
                    Button("保存済み配置を再読込", action: onReload)
                        .accessibilityLabel("保存済み配置の診断を再読込")
                        .accessibilityIdentifier(SceneShelfPersistencePresentation.reloadButtonIdentifier)
                } else {
                    Text("保存先の初期化に失敗したため再読込できません。設定を確認してアプリを再起動してください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("persistence-diagnostics")
    }
}
