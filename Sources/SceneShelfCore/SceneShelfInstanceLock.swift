import Darwin
import Foundation

public enum SceneShelfInstanceLockError: Error, Equatable, Sendable {
    case alreadyRunning
    case systemFailure(Int32)

    public var japaneseLabel: String {
        switch self {
        case .alreadyRunning:
            return "別のScene Shelfが起動中です。既存のアプリを終了してから再試行してください"
        case .systemFailure:
            return "Scene Shelfの起動ロックを準備できませんでした。保存先の権限を確認してください"
        }
    }
}

/// Holds the process-wide Scene Shelf ownership lock until `release()` or deinit.
public final class SceneShelfInstanceLock: @unchecked Sendable {
    public let lockURL: URL

    private var fileDescriptor: Int32?

    private init(lockURL: URL, fileDescriptor: Int32) {
        self.lockURL = lockURL
        self.fileDescriptor = fileDescriptor
    }

    public static func acquire(at url: URL) throws -> SceneShelfInstanceLock {
        let lockURL = url.standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw SceneShelfInstanceLockError.systemFailure(Int32(EIO))
        }

        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SceneShelfInstanceLockError.systemFailure(errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN {
                throw SceneShelfInstanceLockError.alreadyRunning
            }
            throw SceneShelfInstanceLockError.systemFailure(failure)
        }

        return SceneShelfInstanceLock(lockURL: lockURL, fileDescriptor: descriptor)
    }

    public func release() {
        guard let fileDescriptor else { return }
        _ = flock(fileDescriptor, LOCK_UN)
        _ = close(fileDescriptor)
        self.fileDescriptor = nil
    }

    deinit {
        release()
    }
}
