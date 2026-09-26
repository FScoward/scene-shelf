import Foundation
import Darwin

public enum ScenePersistenceError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case corruptIndex
    case unsupportedIndexVersion(Int)
    case invalidIndex
    case revisionAlreadyExists(SceneID)
    case atomicWriteFailed
    case saveRejectedAfterLoadFailure

    public var japaneseLabel: String {
        switch self {
        case .applicationSupportUnavailable:
            return "保存先を準備できませんでした"
        case .corruptIndex:
            return "保存済み配置の一覧が壊れているため、保存を停止しました"
        case let .unsupportedIndexVersion(version):
            return "保存済み配置の一覧（schema version \(version)）には対応していません"
        case .invalidIndex:
            return "保存済み配置の一覧を検証できないため、保存を停止しました"
        case let .revisionAlreadyExists(sceneID):
            return "配置 \(sceneID) の保存履歴が既に存在します"
        case .atomicWriteFailed:
            return "保存済み配置を安全に更新できませんでした"
        case .saveRejectedAfterLoadFailure:
            return "保存済み配置の読み込みに失敗したため、上書きを停止しました"
        }
    }
}

public enum ScenePersistenceFault: Equatable, Sendable {
    case none
    case indexCommit
    case cleanup
    case orphanScan
    case preRenameDurability
    case postRenameDurability
}

public enum ScenePersistenceDiagnosticKind: String, Codable, Equatable, Sendable {
    case missingRevision
    case corruptRevision
    case unsupportedRevisionVersion
    case invalidRevision
    case orphanRevision
}

public struct ScenePersistenceDiagnostic: Codable, Equatable, Sendable {
    public let kind: ScenePersistenceDiagnosticKind
    public let sceneID: SceneID
    public let path: String
    public let detail: String

    public init(
        kind: ScenePersistenceDiagnosticKind,
        sceneID: SceneID,
        path: String,
        detail: String
    ) {
        self.kind = kind
        self.sceneID = sceneID
        self.path = path
        self.detail = detail
    }
}

public struct ScenePersistenceIndexEntry: Codable, Equatable, Sendable {
    public let sceneID: SceneID
    public let revision: Int
    public let name: String
    public let order: Int

    public init(sceneID: SceneID, revision: Int, name: String, order: Int) {
        self.sceneID = sceneID
        self.revision = revision
        self.name = name
        self.order = order
    }
}

public struct ScenePersistenceLoadResult: Equatable, Sendable {
    public let scenes: [SavedScene]
    public let indexEntries: [ScenePersistenceIndexEntry]
    public let diagnostics: [ScenePersistenceDiagnostic]

    public init(
        scenes: [SavedScene],
        indexEntries: [ScenePersistenceIndexEntry],
        diagnostics: [ScenePersistenceDiagnostic]
    ) {
        self.scenes = scenes
        self.indexEntries = indexEntries
        self.diagnostics = diagnostics
    }
}

/// The on-disk boundary for saved scenes.
///
/// `index.json` is the commit point. Immutable revision files are published
/// before the index is replaced, so a failed index update cannot cause an
/// existing scene revision to be overwritten with empty data.
public struct SceneShelfPersistence: Sendable {
    public static let currentSchemaVersion = 1

    public let rootURL: URL
    public let fault: ScenePersistenceFault

    private var indexURL: URL {
        rootURL.appendingPathComponent("index.json", isDirectory: false)
    }

    private var scenesDirectoryURL: URL {
        rootURL.appendingPathComponent("scenes", isDirectory: true)
    }

    public init(rootURL: URL, fault: ScenePersistenceFault = .none) {
        self.rootURL = rootURL.standardizedFileURL
        self.fault = fault
    }

    public static func applicationSupport() throws -> SceneShelfPersistence {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ScenePersistenceError.applicationSupportUnavailable
        }
        return SceneShelfPersistence(
            rootURL: applicationSupportURL.appendingPathComponent("SceneShelf", isDirectory: true)
        )
    }

    public func load() throws -> ScenePersistenceLoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return ScenePersistenceLoadResult(
                scenes: [],
                indexEntries: [],
                diagnostics: try orphanRevisionDiagnostics(indexEntries: [])
            )
        }

        let indexData: Data
        do {
            indexData = try Data(contentsOf: indexURL)
        } catch {
            throw ScenePersistenceError.corruptIndex
        }

        let document: IndexDocument
        do {
            document = try JSONDecoder().decode(IndexDocument.self, from: indexData)
        } catch {
            throw ScenePersistenceError.corruptIndex
        }
        guard document.schemaVersion == Self.currentSchemaVersion else {
            throw ScenePersistenceError.unsupportedIndexVersion(document.schemaVersion)
        }

        let sortedEntries = document.entries.sorted { lhs, rhs in
            if lhs.order == rhs.order {
                return lhs.sceneID < rhs.sceneID
            }
            return lhs.order < rhs.order
        }
        guard isValidIndex(sortedEntries) else {
            throw ScenePersistenceError.invalidIndex
        }

        var scenes: [SavedScene] = []
        var diagnostics: [ScenePersistenceDiagnostic] = []
        for entry in sortedEntries {
            let revisionURL = revisionURL(for: entry)
            guard fileManager.fileExists(atPath: revisionURL.path) else {
                diagnostics.append(
                    ScenePersistenceDiagnostic(
                        kind: .missingRevision,
                        sceneID: entry.sceneID,
                        path: revisionURL.path,
                        detail: "revision file is missing"
                    )
                )
                continue
            }

            let revisionData: Data
            do {
                revisionData = try Data(contentsOf: revisionURL)
            } catch {
                diagnostics.append(
                    ScenePersistenceDiagnostic(
                        kind: .corruptRevision,
                        sceneID: entry.sceneID,
                        path: revisionURL.path,
                        detail: "revision file could not be read"
                    )
                )
                continue
            }

            let revision: RevisionDocument
            do {
                revision = try JSONDecoder().decode(RevisionDocument.self, from: revisionData)
            } catch {
                diagnostics.append(
                    ScenePersistenceDiagnostic(
                        kind: .corruptRevision,
                        sceneID: entry.sceneID,
                        path: revisionURL.path,
                        detail: "revision JSON could not be decoded"
                    )
                )
                continue
            }
            guard revision.schemaVersion == Self.currentSchemaVersion else {
                diagnostics.append(
                    ScenePersistenceDiagnostic(
                        kind: .unsupportedRevisionVersion,
                        sceneID: entry.sceneID,
                        path: revisionURL.path,
                        detail: "schema version \(revision.schemaVersion) is unsupported"
                    )
                )
                continue
            }
            guard revision.sceneID == entry.sceneID else {
                diagnostics.append(
                    ScenePersistenceDiagnostic(
                        kind: .invalidRevision,
                        sceneID: entry.sceneID,
                        path: revisionURL.path,
                        detail: "revision scene ID does not match index"
                    )
                )
                continue
            }
            guard !revision.windows.isEmpty else {
                diagnostics.append(
                    ScenePersistenceDiagnostic(
                        kind: .invalidRevision,
                        sceneID: entry.sceneID,
                        path: revisionURL.path,
                        detail: "revision must contain at least one window"
                    )
                )
                continue
            }
            guard Set(revision.windows.map(\.identity)).count == revision.windows.count else {
                diagnostics.append(
                    ScenePersistenceDiagnostic(
                        kind: .invalidRevision,
                        sceneID: entry.sceneID,
                        path: revisionURL.path,
                        detail: "revision contains duplicate window identities"
                    )
                )
                continue
            }

            scenes.append(
                SavedScene(
                    id: entry.sceneID,
                    name: entry.name,
                    windows: revision.windows
                )
            )
        }

        // Keep orphan revisions untouched, but surface them for diagnosis.
        diagnostics.append(contentsOf: try orphanRevisionDiagnostics(indexEntries: sortedEntries))

        return ScenePersistenceLoadResult(
            scenes: scenes,
            indexEntries: sortedEntries,
            diagnostics: diagnostics
        )
    }

    public func commit(
        scene: SavedScene,
        revision: Int,
        indexEntries: [ScenePersistenceIndexEntry]
    ) throws {
        guard revision > 0,
              isSafeFileComponent(scene.id),
              !scene.windows.isEmpty,
              Set(scene.windows.map(\.identity)).count == scene.windows.count else {
            throw ScenePersistenceError.invalidIndex
        }
        guard let currentEntry = indexEntries.first(where: { $0.sceneID == scene.id }),
              currentEntry.revision == revision,
              currentEntry.name == scene.name,
              Set(indexEntries.map(\.sceneID)).count == indexEntries.count,
              Set(indexEntries.map(\.order)).count == indexEntries.count,
              indexEntries.allSatisfy({ $0.revision > 0 && isSafeFileComponent($0.sceneID) }) else {
            throw ScenePersistenceError.invalidIndex
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scenesDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw ScenePersistenceError.atomicWriteFailed
        }

        let revisionURL = revisionURL(for: currentEntry)
        if fileManager.fileExists(atPath: revisionURL.path) {
            throw ScenePersistenceError.revisionAlreadyExists(scene.id)
        }

        let revisionData: Data
        do {
            revisionData = try JSONEncoder.sceneShelfEncoder.encode(
                RevisionDocument(
                    schemaVersion: Self.currentSchemaVersion,
                    sceneID: scene.id,
                    windows: scene.windows
                )
            )
        } catch {
            throw ScenePersistenceError.atomicWriteFailed
        }
        try Self.atomicWrite(
            revisionData,
            to: revisionURL,
            allowingReplace: false,
            fault: fault
        )

        try commitIndex(indexEntries: indexEntries)
    }

    /// Commits metadata only. The index remains the single commit point for
    /// rename, reorder, and delete operations.
    public func commitIndex(indexEntries: [ScenePersistenceIndexEntry]) throws {
        guard isValidIndex(indexEntries) else {
            throw ScenePersistenceError.invalidIndex
        }
        guard fault != .indexCommit else {
            throw ScenePersistenceError.atomicWriteFailed
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scenesDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw ScenePersistenceError.atomicWriteFailed
        }

        let indexData: Data
        do {
            indexData = try JSONEncoder.sceneShelfEncoder.encode(
                IndexDocument(
                    schemaVersion: Self.currentSchemaVersion,
                    entries: indexEntries.sorted { lhs, rhs in
                        if lhs.order == rhs.order {
                            return lhs.sceneID < rhs.sceneID
                        }
                        return lhs.order < rhs.order
                    }
                )
            )
        } catch {
            throw ScenePersistenceError.atomicWriteFailed
        }
        try Self.atomicWrite(
            indexData,
            to: indexURL,
            allowingReplace: true,
            fault: fault
        )
    }

    /// Returns the first revision number that cannot collide with an existing
    /// immutable revision file. Orphan revisions remain available for
    /// diagnosis, so callers must skip them instead of deleting or reusing
    /// their numbers.
    public func nextAvailableRevision(sceneID: SceneID, after revision: Int) throws -> Int {
        guard revision >= 0, isSafeFileComponent(sceneID) else {
            throw ScenePersistenceError.invalidIndex
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scenesDirectoryURL.path) else {
            return try checkedIncrement(revision)
        }

        let prefix = "\(sceneID)-"
        let suffix = ".json"
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: scenesDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ScenePersistenceError.atomicWriteFailed
        }

        let highestExistingRevision = files.compactMap { file -> Int? in
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
                return nil
            }
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -suffix.count)
            guard start < end else {
                return nil
            }
            let revisionText = String(name[start..<end])
            guard let value = Int(revisionText), value > 0 else {
                return nil
            }
            return value
        }.max() ?? 0

        let nextRevision = try checkedIncrement(revision)
        let nextExistingRevision = try checkedIncrement(highestExistingRevision)
        return max(nextRevision, nextExistingRevision)
    }

    /// Returns the first generated scene number that cannot collide with any
    /// orphan revision filename currently on disk.
    public func nextAvailableSceneNumber(after sceneNumber: Int) throws -> Int {
        guard sceneNumber >= 0 else {
            throw ScenePersistenceError.invalidIndex
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scenesDirectoryURL.path) else {
            return try checkedIncrement(sceneNumber)
        }
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: scenesDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ScenePersistenceError.atomicWriteFailed
        }
        let highestExistingNumber = files.compactMap { file -> Int? in
            guard let (sceneID, _) = revisionIdentity(for: file),
                  sceneID.hasPrefix("scene-"),
                  let number = Int(sceneID.dropFirst("scene-".count)) else {
                return nil
            }
            return number
        }.max() ?? 0
        let nextSceneNumber = try checkedIncrement(sceneNumber)
        let nextExistingNumber = try checkedIncrement(highestExistingNumber)
        return max(nextSceneNumber, nextExistingNumber)
    }

    /// Deletes only revisions that are no longer referenced after an index
    /// commit. A cleanup failure is intentionally reported separately from the
    /// index commit so callers can keep the deletion and diagnose an orphan.
    public func cleanupRevisions(for sceneID: SceneID) throws {
        guard isSafeFileComponent(sceneID) else {
            throw ScenePersistenceError.invalidIndex
        }
        guard fault != .cleanup else {
            throw ScenePersistenceError.atomicWriteFailed
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scenesDirectoryURL.path) else {
            return
        }
        let files = try fileManager.contentsOfDirectory(
            at: scenesDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files {
            guard let (candidateSceneID, _) = revisionIdentity(for: file),
                  candidateSceneID == sceneID else {
                continue
            }
            try fileManager.removeItem(at: file)
        }
    }

    private func revisionURL(for entry: ScenePersistenceIndexEntry) -> URL {
        scenesDirectoryURL.appendingPathComponent(
            "\(entry.sceneID)-\(entry.revision).json",
            isDirectory: false
        )
    }

    private func revisionIdentity(for url: URL) -> (sceneID: SceneID, revision: Int)? {
        guard url.pathExtension == "json" else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard let separator = stem.lastIndex(of: "-") else { return nil }
        let sceneID = String(stem[..<separator])
        let revisionText = String(stem[stem.index(after: separator)...])
        guard isSafeFileComponent(sceneID), let revision = Int(revisionText), revision > 0 else {
            return nil
        }
        return (sceneID, revision)
    }

    private func orphanRevisionDiagnostics(
        indexEntries: [ScenePersistenceIndexEntry]
    ) throws -> [ScenePersistenceDiagnostic] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scenesDirectoryURL.path) else {
            return []
        }
        guard fault != .orphanScan else {
            throw ScenePersistenceError.atomicWriteFailed
        }
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: scenesDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ScenePersistenceError.atomicWriteFailed
        }
        let referencedPaths = Set(indexEntries.map { revisionURL(for: $0).standardizedFileURL.path })
        let indexedRevisions = Dictionary(uniqueKeysWithValues: indexEntries.map { ($0.sceneID, $0.revision) })
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  !referencedPaths.contains(file.standardizedFileURL.path),
                  let (sceneID, revision) = revisionIdentity(for: file),
                  indexedRevisions[sceneID] == nil || revision > indexedRevisions[sceneID, default: 0] else {
                return nil
            }
            return ScenePersistenceDiagnostic(
                kind: .orphanRevision,
                sceneID: sceneID,
                path: file.path,
                detail: "revision file is not referenced by index"
            )
        }
    }

    private func checkedIncrement(_ value: Int) throws -> Int {
        let (result, overflow) = value.addingReportingOverflow(1)
        guard !overflow else {
            throw ScenePersistenceError.atomicWriteFailed
        }
        return result
    }

    private func isValidIndex(_ entries: [ScenePersistenceIndexEntry]) -> Bool {
        Set(entries.map(\.sceneID)).count == entries.count
            && Set(entries.map(\.order)).count == entries.count
            && entries.allSatisfy {
                $0.revision > 0
                    && $0.order >= 0
                    && $0.order < Int.max
                    && isSafeFileComponent($0.sceneID)
            }
    }

    private func isSafeFileComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }

    private static func atomicWrite(
        _ data: Data,
        to url: URL,
        allowingReplace: Bool,
        fault: ScenePersistenceFault
    ) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")

        // Before rename, the destination still contains the previous
        // published value. A failure here must leave callers free to retain
        // their old in-memory state.
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            try syncFile(at: temporaryURL)
            if fault == .preRenameDurability {
                throw POSIXError(.EIO)
            }

            let renameFlags: UInt32 = allowingReplace ? 0 : UInt32(RENAME_EXCL)
            guard renameatx_np(
                AT_FDCWD,
                temporaryURL.path,
                AT_FDCWD,
                url.path,
                renameFlags
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ScenePersistenceError.atomicWriteFailed
        }

        // Rename has published the new bytes. A subsequent fsync failure is
        // therefore not equivalent to a pre-rename failure: verify the
        // published destination before deciding whether the caller should
        // observe a failure. Matching bytes converge disk and memory on the
        // new commit even when durability could not be confirmed.
        do {
            if fault == .postRenameDurability {
                throw POSIXError(.EIO)
            }
            try syncFile(at: url)
            try syncDirectory(at: url.deletingLastPathComponent())
        } catch {
            guard let publishedData = try? Data(contentsOf: url), publishedData == data else {
                throw ScenePersistenceError.atomicWriteFailed
            }
        }
    }

    private static func syncFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func syncDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private struct IndexDocument: Codable, Sendable {
    let schemaVersion: Int
    let entries: [ScenePersistenceIndexEntry]
}

private struct RevisionDocument: Codable, Sendable {
    let schemaVersion: Int
    let sceneID: SceneID
    let windows: [SceneWindowSnapshot]
}

private extension JSONEncoder {
    static var sceneShelfEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
