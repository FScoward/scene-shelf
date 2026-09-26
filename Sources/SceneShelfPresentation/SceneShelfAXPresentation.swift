import SceneShelfAccessibility
import SceneShelfCore

/// Pure presentation boundary for AX discovery failures.
///
/// The AppKit/SwiftUI ViewModel owns asynchronous orchestration. This value
/// layer owns only the user-visible Japanese messages and the conversion from
/// a discovery failure to a target-specific restore report, so every entry
/// point presents the same reason without exposing AX objects to the UI.
public enum SceneShelfAXPresentation {
    public static func discoveryMessage(
        for result: AXWindowDiscoveryResult
    ) -> String {
        if let failureReason = result.failureReason {
            return failureReason.japaneseLabel
        }
        return "Fixtureのウィンドウを\(result.windows.count)件検出しました"
    }

    public static func saveFailureMessage(
        for error: AXSceneCaptureError
    ) -> String {
        if case let .discoveryFailed(reason) = error {
            return "保存対象を取得できないため、保存を中止しました: \(reason.japaneseLabel)"
        }
        return error.japaneseLabel
    }

    public static func overwriteFailureMessage(
        for reason: FailureReason
    ) -> String {
        "現在の配置を取得できません: \(reason.japaneseLabel)"
    }

    public static func restoreReport(
        for plan: SceneRestorePlan,
        discoveryFailure reason: FailureReason
    ) -> SceneRestoreReport {
        let sceneReason = SceneFailureReason(rawValue: reason.rawValue) ?? .operationFailed
        return SceneRestoreReport(
            sceneID: plan.sceneID,
            action: plan.action,
            outcomes: plan.instructions.map {
                .failed(target: $0.target, reason: sceneReason)
            }
        )
    }
}
