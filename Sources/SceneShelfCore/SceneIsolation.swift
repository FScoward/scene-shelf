import Foundation

/// A background window is safe to restore only after the active scene has
/// disappeared. A failed hide keeps its scene as the safety anchor, while a
/// fully failed display leaves no active scene and is safe to roll back.
public enum SceneBackgroundRestorePolicy {
    public static func shouldRestore(after report: SceneRestoreReport?) -> Bool {
        guard let report else { return false }
        return report.currentSceneID == nil
    }
}
