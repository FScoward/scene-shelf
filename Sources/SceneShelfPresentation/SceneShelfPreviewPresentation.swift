import Foundation
import SceneShelfCore

/// A window rectangle expressed in the unit square used by the saved-scene shelf.
public struct SceneShelfPreviewFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }

    public var isUnitRange: Bool {
        (0...1).contains(x)
            && (0...1).contains(y)
            && (0...1).contains(width)
            && (0...1).contains(height)
            && x + width <= 1
            && y + height <= 1
    }
}

public struct SceneShelfPreviewWindow: Equatable, Sendable, Identifiable {
    public let id: String
    public let frame: SceneShelfPreviewFrame

    public init(id: String, frame: SceneShelfPreviewFrame) {
        self.id = id
        self.frame = frame
    }
}

public struct SceneShelfPreview: Equatable, Sendable, Identifiable {
    public let sceneID: SceneID
    public let windows: [SceneShelfPreviewWindow]
    public let contentAspectRatio: Double

    public var id: SceneID { sceneID }

    public init(
        sceneID: SceneID,
        windows: [SceneShelfPreviewWindow],
        contentAspectRatio: Double = 1
    ) {
        self.sceneID = sceneID
        self.windows = windows
        self.contentAspectRatio = contentAspectRatio.isFinite && contentAspectRatio > 0
            ? contentAspectRatio
            : 1
    }
}

/// Builds a deterministic, privacy-preserving visual summary from saved frames.
public enum SceneShelfPreviewPresentation {
    public static func preview(for scene: SavedScene) -> SceneShelfPreview {
        let frames = scene.windows.map { rawFrame in
            SanitizedFrame(
                x: finiteOrZero(rawFrame.frame.x),
                y: finiteOrZero(rawFrame.frame.y),
                width: nonNegativeFiniteOrZero(rawFrame.frame.width),
                height: nonNegativeFiniteOrZero(rawFrame.frame.height)
            )
        }

        guard !frames.isEmpty else {
            return SceneShelfPreview(sceneID: scene.id, windows: [])
        }

        let minX = frames.map(\.x).min() ?? 0
        let minY = frames.map(\.y).min() ?? 0
        let maxX = frames.map { $0.x + $0.width }.max() ?? minX
        let maxY = frames.map { $0.y + $0.height }.max() ?? minY
        let unionWidth = safeSpan(maxX - minX)
        let unionHeight = safeSpan(maxY - minY)

        let windows = frames.enumerated().map { index, frame in
            SceneShelfPreviewWindow(
                id: scene.windows[index].id,
                frame: SceneShelfPreviewFrame(
                    x: clamp((frame.x - minX) / unionWidth),
                    y: clamp((frame.y - minY) / unionHeight),
                    width: clamp(frame.width / unionWidth),
                    height: clamp(frame.height / unionHeight)
                )
            )
        }
        return SceneShelfPreview(
            sceneID: scene.id,
            windows: windows,
            contentAspectRatio: unionWidth / unionHeight
        )
    }

    /// Returns the aspect-fit drawing area used by the thumbnail renderer.
    public static func contentRect(
        for preview: SceneShelfPreview,
        in size: CGSize
    ) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return .zero
        }
        let aspectRatio = preview.contentAspectRatio
        let fittedSize: CGSize
        if size.width / size.height > aspectRatio {
            fittedSize = CGSize(width: size.height * aspectRatio, height: size.height)
        } else {
            fittedSize = CGSize(width: size.width, height: size.width / aspectRatio)
        }
        return CGRect(
            x: (size.width - fittedSize.width) / 2,
            y: (size.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    public static func previews(
        for scenes: [SavedScene]
    ) -> [SceneID: SceneShelfPreview] {
        Dictionary(uniqueKeysWithValues: scenes.map { scene in
            (scene.id, preview(for: scene))
        })
    }

    private struct SanitizedFrame {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private static func finiteOrZero(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func nonNegativeFiniteOrZero(_ value: Double) -> Double {
        max(0, finiteOrZero(value))
    }

    private static func safeSpan(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}
