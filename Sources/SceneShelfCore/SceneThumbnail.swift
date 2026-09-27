import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

public enum SceneThumbnailCaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case windowMissing(SceneWindowIdentity)
    case ambiguousWindow(SceneWindowIdentity)
    case captureFailed
    case invalidImage

    public var japaneseLabel: String {
        switch self {
        case .permissionDenied:
            return "画面収録権限がありません。許可後にアプリを再起動してください"
        case .windowMissing:
            return "対象ウィンドウが見つからないため、プレビューを作成できません"
        case .ambiguousWindow:
            return "対象ウィンドウを一意に特定できないため、プレビューを作成できません"
        case .captureFailed, .invalidImage:
            return "ウィンドウのプレビューを取得できませんでした"
        }
    }
}

public enum SceneThumbnailCacheError: Error, Equatable, Sendable {
    case invalidSceneID
    case atomicWriteFailed
    case missingSource

    public var japaneseLabel: String {
        switch self {
        case .invalidSceneID:
            return "配置名を安全なファイル名に変換できません"
        case .atomicWriteFailed:
            return "配置プレビューを安全に更新できませんでした"
        case .missingSource:
            return "複製元の配置プレビューがありません"
        }
    }
}

public enum SceneThumbnailCacheFault: Equatable, Sendable {
    case none
    case beforeRename
}

public enum SceneThumbnailState: Equatable, Sendable {
    case loading
    case available
    case fallback
    case failed(String)
}

public struct SceneThumbnailSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// An immutable, portable RGBA8 raster used at the ScreenCaptureKit boundary.
/// Keeping pixels as value data lets the compositor and cache tests run without
/// requiring an active display or a Screen Recording permission.
public struct SceneThumbnailImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgbaData: Data

    public init(width: Int, height: Int, rgbaData: Data) {
        self.width = width
        self.height = height
        self.rgbaData = rgbaData
    }

    public static func solidColor(width: Int, height: Int, rgba: [UInt8]) -> SceneThumbnailImage {
        var pixel = Array(rgba.prefix(4))
        pixel.append(contentsOf: repeatElement(0, count: max(0, 4 - pixel.count)))
        var repeated = Data()
        for _ in 0..<max(0, width * height) {
            repeated.append(contentsOf: pixel)
        }
        return SceneThumbnailImage(width: width, height: height, rgbaData: repeated)
    }

    public var isValid: Bool {
        width > 0 && height > 0 && rgbaData.count == width * height * 4
    }

    public init(cgImage: CGImage) throws {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw SceneThumbnailCaptureError.invalidImage
        }
        var pixels = Data(repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let drawn = pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }
            // CGImage data is conventionally top-to-bottom while a bitmap
            // CGContext's default user space starts at the lower-left.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw SceneThumbnailCaptureError.invalidImage
        }
        self.init(width: width, height: height, rgbaData: pixels)
    }

    public func pngData() throws -> Data {
        guard isValid else {
            throw SceneThumbnailCaptureError.invalidImage
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: rgbaData as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw SceneThumbnailCaptureError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw SceneThumbnailCaptureError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SceneThumbnailCaptureError.invalidImage
        }
        return output as Data
    }
}

public struct SceneThumbnailWindowDescriptor: Equatable, Sendable {
    public let bundleIdentifier: String
    public let processID: Int32
    public let title: String
    public let frame: SceneFrame?
    public let windowLayer: Int
    public let sharingState: Int

    public init(
        bundleIdentifier: String,
        processID: Int32,
        title: String,
        frame: SceneFrame? = nil,
        windowLayer: Int = 0,
        sharingState: Int = 1
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.title = title
        self.frame = frame
        self.windowLayer = windowLayer
        self.sharingState = sharingState
    }
}

public enum SceneThumbnailWindowResolution: Equatable, Sendable {
    case unique
    case missing
    case ambiguous

    public static func resolve(
        identity: SceneWindowIdentity,
        candidates: [SceneThumbnailWindowDescriptor],
        savedFrame: SceneFrame? = nil
    ) -> SceneThumbnailWindowResolution {
        let exactMatches = candidates.filter {
            $0.bundleIdentifier == identity.bundleIdentifier
                && $0.processID == identity.processID
                && $0.title == identity.title
        }
        switch exactMatches.count {
        case 0: return .missing
        default:
            return uniqueMatchIndex(
                identity: identity,
                candidates: candidates,
                savedFrame: savedFrame
            ) == nil ? .ambiguous : .unique
        }
    }

    public static func uniqueMatchIndex(
        identity: SceneWindowIdentity,
        candidates: [SceneThumbnailWindowDescriptor],
        savedFrame: SceneFrame? = nil
    ) -> Int? {
        let exactIndices = candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.bundleIdentifier == identity.bundleIdentifier
                && candidate.processID == identity.processID
                && candidate.title == identity.title
        }
        guard !exactIndices.isEmpty else { return nil }
        if exactIndices.count == 1 { return exactIndices[0] }
        guard let savedFrame else { return nil }
        let nearIndices = exactIndices.filter { index in
            guard let frame = candidates[index].frame else { return false }
            return frame.isApproximatelyEqual(to: savedFrame, tolerance: 4)
        }
        return nearIndices.count == 1 ? nearIndices[0] : nil
    }

    public static func capturableCandidates(
        _ candidates: [SceneThumbnailWindowDescriptor]
    ) -> [SceneThumbnailWindowDescriptor] {
        candidates.filter { candidate in
            candidate.windowLayer == 0
                && candidate.sharingState != 0
                && (candidate.frame.map { $0.width > 0 && $0.height > 0 } ?? true)
        }
    }
}

private extension SceneFrame {
    func isApproximatelyEqual(to other: SceneFrame, tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

public enum SceneThumbnailCaptureSizing {
    public static func outputSize(
        for frame: SceneFrame,
        maximumSize: SceneThumbnailSize = SceneThumbnailSize(width: 400, height: 280)
    ) -> SceneThumbnailSize {
        let width = max(1, frame.width.isFinite ? frame.width : 1)
        let height = max(1, frame.height.isFinite ? frame.height : 1)
        let scale = min(
            Double(maximumSize.width) / width,
            Double(maximumSize.height) / height,
            1
        )
        return SceneThumbnailSize(
            width: max(1, Int((width * scale).rounded(.down))),
            height: max(1, Int((height * scale).rounded(.down)))
        )
    }
}

public enum SceneThumbnailComposer {
    public static func compose(
        scene: SavedScene,
        images: [SceneWindowIdentity: SceneThumbnailImage],
        maximumSize: SceneThumbnailSize = SceneThumbnailSize(width: 400, height: 280)
    ) throws -> SceneThumbnailImage {
        guard !scene.windows.isEmpty,
              maximumSize.width > 0,
              maximumSize.height > 0 else {
            throw SceneThumbnailCaptureError.invalidImage
        }

        let frames = scene.windows.map { snapshot in
            let frame = snapshot.frame
            return SceneFrame(
                x: frame.x.isFinite ? frame.x : 0,
                y: frame.y.isFinite ? frame.y : 0,
                width: frame.width.isFinite ? max(0, frame.width) : 0,
                height: frame.height.isFinite ? max(0, frame.height) : 0
            )
        }
        let minX = frames.map(\.x).min() ?? 0
        let minY = frames.map(\.y).min() ?? 0
        let maxX = frames.map { $0.x + $0.width }.max() ?? minX
        let maxY = frames.map { $0.y + $0.height }.max() ?? minY
        let unionWidth = max(1, maxX - minX)
        let unionHeight = max(1, maxY - minY)
        let scale = min(
            Double(maximumSize.width) / unionWidth,
            Double(maximumSize.height) / unionHeight
        )
        let outputWidth = max(1, Int((unionWidth * scale).rounded(.down)))
        let outputHeight = max(1, Int((unionHeight * scale).rounded(.down)))
        var output = Data(repeating: 0, count: outputWidth * outputHeight * 4)

        for (index, snapshot) in scene.windows.enumerated() {
            guard let image = images[snapshot.identity], image.isValid else {
                throw SceneThumbnailCaptureError.captureFailed
            }
            let frame = frames[index]
            let x = max(0, Int(((frame.x - minX) * scale).rounded(.down)))
            let y = max(0, Int(((frame.y - minY) * scale).rounded(.down)))
            let width = min(outputWidth - x, max(1, Int((frame.width * scale).rounded(.down))))
            let height = min(outputHeight - y, max(1, Int((frame.height * scale).rounded(.down))))
            guard width > 0, height > 0 else { continue }

            for destinationY in 0..<height {
                let sourceY = min(image.height - 1, destinationY * image.height / height)
                for destinationX in 0..<width {
                    let sourceX = min(image.width - 1, destinationX * image.width / width)
                    let sourceOffset = (sourceY * image.width + sourceX) * 4
                    let destinationOffset = ((y + destinationY) * outputWidth + x + destinationX) * 4
                    output.replaceSubrange(
                        destinationOffset..<(destinationOffset + 4),
                        with: image.rgbaData[sourceOffset..<(sourceOffset + 4)]
                    )
                }
            }
        }
        return SceneThumbnailImage(width: outputWidth, height: outputHeight, rgbaData: output)
    }
}

public protocol SceneThumbnailCapturing: Sendable {
    func capture(scene: SavedScene) async throws -> Data
}

public struct SceneThumbnailCache: Sendable {
    public let rootURL: URL
    public let fault: SceneThumbnailCacheFault

    private var thumbnailsURL: URL {
        rootURL.appendingPathComponent("thumbnails", isDirectory: true)
    }

    public init(rootURL: URL, fault: SceneThumbnailCacheFault = .none) {
        self.rootURL = rootURL.standardizedFileURL
        self.fault = fault
    }

    public func url(for sceneID: SceneID) throws -> URL {
        guard Self.isSafeFileComponent(sceneID) else {
            throw SceneThumbnailCacheError.invalidSceneID
        }
        return thumbnailsURL.appendingPathComponent("\(sceneID).png", isDirectory: false)
    }

    public func read(sceneID: SceneID) throws -> Data? {
        let destination = try url(for: sceneID)
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return try Data(contentsOf: destination)
    }

    public func write(_ data: Data, sceneID: SceneID) throws {
        let destination = try url(for: sceneID)
        do {
            try FileManager.default.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
            let temporary = thumbnailsURL.appendingPathComponent(
                ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
            )
            do {
                try data.write(to: temporary, options: [.atomic])
                if fault == .beforeRename {
                    throw POSIXError(.EIO)
                }
                guard rename(temporary.path, destination.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        } catch let error as SceneThumbnailCacheError {
            throw error
        } catch {
            throw SceneThumbnailCacheError.atomicWriteFailed
        }
    }

    public func copy(from sourceSceneID: SceneID, to destinationSceneID: SceneID) throws {
        guard let data = try read(sceneID: sourceSceneID) else {
            throw SceneThumbnailCacheError.missingSource
        }
        try write(data, sceneID: destinationSceneID)
    }

    public func remove(sceneID: SceneID) throws {
        let destination = try url(for: sceneID)
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            throw SceneThumbnailCacheError.atomicWriteFailed
        }
    }

    private static func isSafeFileComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (
                    scalar.properties.isAlphabetic
                        || (48...57).contains(Int(scalar.value))
                        || "-_".unicodeScalars.contains(scalar)
                )
            }
    }
}
