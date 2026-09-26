import SceneShelfCore

/// Pure presentation and refresh policy for saved-scene management failures.
///
/// A cleanup failure is deliberately non-atomic: the scene record has already
/// been removed, while an obsolete file could not be deleted. The ViewModel
/// must therefore keep the warning and refresh its cards from the store.
public enum SceneShelfManagementPresentation {
    public static func message(for error: Error) -> String {
        if let managementError = error as? SceneManagementError {
            return managementError.japaneseLabel
        }
        if let persistenceError = error as? ScenePersistenceError {
            return persistenceError.japaneseLabel
        }
        return "配置を更新できませんでした"
    }

    public static func shouldRefreshAfterDeleteFailure(_ error: Error) -> Bool {
        guard let managementError = error as? SceneManagementError else {
            return false
        }
        if case .cleanupFailed = managementError {
            return true
        }
        return false
    }
}
