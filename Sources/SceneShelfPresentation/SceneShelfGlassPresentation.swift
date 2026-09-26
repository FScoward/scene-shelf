import Foundation
import SwiftUI

public enum SceneShelfGlassSurface: Equatable, Sendable {
    case header
    case card
}

public struct SceneShelfGlassRenderingConfiguration: Equatable, Sendable {
    public enum Platform: Equatable, Sendable {
        case nativeGlass
        case materialFallback
    }

    public enum Surface: Equatable, Sendable {
        case clear
        case regular
    }

    public enum Button: Equatable, Sendable {
        case glass
        case bordered
    }

    public let platform: Platform
    public let surface: Surface
    public let isInteractive: Bool
    public let outlineOpacity: Double
    public let button: Button

    public init(
        platform: Platform,
        surface: Surface,
        isInteractive: Bool,
        outlineOpacity: Double,
        button: Button
    ) {
        self.platform = platform
        self.surface = surface
        self.isInteractive = isInteractive
        self.outlineOpacity = outlineOpacity
        self.button = button
    }
}

public enum SceneShelfGlassPresentation {
    public static let nativeGlassMajorVersion = 26

    public static func renderingConfiguration(
        for surface: SceneShelfGlassSurface,
        version: OperatingSystemVersion,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> SceneShelfGlassRenderingConfiguration {
        let platform: SceneShelfGlassRenderingConfiguration.Platform =
            version.majorVersion >= nativeGlassMajorVersion
                ? .nativeGlass
                : .materialFallback
        let accessibilitySurface = reduceTransparency || increasedContrast
        let glassSurface: SceneShelfGlassRenderingConfiguration.Surface =
            accessibilitySurface ? .regular : .clear
        let button: SceneShelfGlassRenderingConfiguration.Button =
            platform == .nativeGlass ? .glass : .bordered

        return SceneShelfGlassRenderingConfiguration(
            platform: platform,
            surface: glassSurface,
            isInteractive: surface == .card,
            outlineOpacity: accessibilitySurface ? 0.45 : 0.14,
            button: button
        )
    }
}

private struct SceneShelfGlassSurfaceModifier: ViewModifier {
    let surface: SceneShelfGlassSurface

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let configuration = SceneShelfGlassPresentation.renderingConfiguration(
            for: surface,
            version: ProcessInfo.processInfo.operatingSystemVersion,
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
        let shape = RoundedRectangle(
            cornerRadius: surface == .header ? 12 : 10,
            style: .continuous
        )
        let tint = configuration.surface == .clear
            ? Color.black.opacity(0.08)
            : Color.black.opacity(0.12)

        if #available(macOS 26.0, *), configuration.platform == .nativeGlass {
            let glass = configuration.surface == .regular ? Glass.regular : Glass.clear
            let configuredGlass = glass.tint(tint)
            let interactiveGlass = configuration.isInteractive
                ? configuredGlass.interactive()
                : configuredGlass
            content
                .glassEffect(interactiveGlass, in: shape)
                .overlay(
                    shape
                        .stroke(.white.opacity(configuration.outlineOpacity), lineWidth: 0.5)
                        .allowsHitTesting(false)
                )
        } else {
            switch surface {
            case .header where configuration.surface == .clear:
                content
                    .background(.thinMaterial, in: shape)
                    .overlay(shape.fill(tint).allowsHitTesting(false))
                    .overlay(
                        shape
                            .stroke(.white.opacity(configuration.outlineOpacity), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    )
            case .card where configuration.surface == .clear,
                    .header,
                    .card:
                content
                    .background(.regularMaterial, in: shape)
                    .overlay(shape.fill(tint).allowsHitTesting(false))
                    .overlay(
                        shape
                            .stroke(.white.opacity(configuration.outlineOpacity), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    )
            }
        }
    }
}

private struct SceneShelfGlassPrimaryButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let configuration = SceneShelfGlassPresentation.renderingConfiguration(
            for: .header,
            version: ProcessInfo.processInfo.operatingSystemVersion,
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
        if #available(macOS 26.0, *), configuration.button == .glass {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
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
