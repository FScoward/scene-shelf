import Foundation
import SwiftUI

public enum SceneShelfGlassSurface: Equatable, Sendable {
    case header
    case card
}

public enum SceneShelfGlassPolicy: Equatable, Sendable {
    case nativeGlass
    case materialFallback
}

public enum SceneShelfGlassPresentation {
    public static let nativeGlassMajorVersion = 26

    public static var currentPolicy: SceneShelfGlassPolicy {
        if #available(macOS 26.0, *) {
            return .nativeGlass
        }
        return .materialFallback
    }

    public static func policy(
        for version: OperatingSystemVersion
    ) -> SceneShelfGlassPolicy {
        version.majorVersion >= nativeGlassMajorVersion
            ? .nativeGlass
            : .materialFallback
    }
}

private struct SceneShelfGlassSurfaceModifier: ViewModifier {
    let surface: SceneShelfGlassSurface

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            switch surface {
            case .header:
                content.glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 12)
                )
            case .card:
                content.glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        } else {
            switch surface {
            case .header:
                content.background(
                    .thinMaterial,
                    in: RoundedRectangle(cornerRadius: 12)
                )
            case .card:
                content.background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
    }
}

private struct SceneShelfGlassPrimaryButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

public extension View {
    func sceneShelfGlassSurface(_ surface: SceneShelfGlassSurface) -> some View {
        modifier(SceneShelfGlassSurfaceModifier(surface: surface))
    }

    func sceneShelfGlassPrimaryButtonStyle() -> some View {
        modifier(SceneShelfGlassPrimaryButtonModifier())
    }
}
