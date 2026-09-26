import SceneShelfCore

public enum SceneFailureMessageFormatter {
    public static func format(_ report: SceneRestoreReport) -> String {
        report.failedOutcomes.map { outcome in
            let reason = outcome.failureReason?.japaneseLabel ?? "理由不明"
            return outcome.target.title + ": " + reason
        }
        .joined(separator: "\n")
    }
}
