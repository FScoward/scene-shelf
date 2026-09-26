import AppKit
import SwiftUI

public enum SceneShelfReadableContentSurfacePresentation {
    public static func backgroundOpacity(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1.0 : 0.88
    }
}

private struct SceneShelfReadableContentSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return content
            .background(
                Color(nsColor: .windowBackgroundColor)
                    .opacity(
                        SceneShelfReadableContentSurfacePresentation.backgroundOpacity(
                            reduceTransparency: reduceTransparency
                        )
                    ),
                in: shape
            )
            .overlay(
                shape.stroke(.separator.opacity(0.35), lineWidth: 0.5)
            )
            .clipShape(shape)
    }
}

public extension View {
    func sceneShelfReadableContentSurface() -> some View {
        modifier(SceneShelfReadableContentSurfaceModifier())
    }
}
