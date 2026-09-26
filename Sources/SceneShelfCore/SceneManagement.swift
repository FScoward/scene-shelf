import Foundation

public enum SceneMoveDirection: String, Equatable, Sendable {
    case up
    case down
}

public enum SceneManagementError: Error, Equatable, Sendable {
    case sceneNotFound(SceneID)
    case emptyName
    case busy
    case confirmationRequired
    case sceneActive(SceneID)
    case orderBoundary
    case targetUnavailable(SceneFailureReason)
    case applicationOverwriteUnsupported
    case cleanupFailed(SceneID)

    public var japaneseLabel: String {
        switch self {
        case let .sceneNotFound(sceneID):
            return "配置 \(sceneID) が見つかりません"
        case .emptyName:
            return "配置名を入力してください"
        case .busy:
            return "別の配置操作を処理中です"
        case .confirmationRequired:
            return "削除の確認が必要です"
        case .sceneActive:
            return "表示中の配置は先にしまってください"
        case .orderBoundary:
            return "これ以上移動できません"
        case let .targetUnavailable(reason):
            return "現在の配置を取得できません: \(reason.japaneseLabel)"
        case .applicationOverwriteUnsupported:
            return "一般アプリ配置の上書きは未対応です。保存内容は変更しません"
        case let .cleanupFailed(sceneID):
            return "配置 \(sceneID) の旧保存ファイルを削除できませんでした。配置の削除は反映済みです"
        }
    }
}
