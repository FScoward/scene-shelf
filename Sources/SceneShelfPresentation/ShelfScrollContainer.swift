import AppKit
import SwiftUI

public enum SceneShelfLayout {
    public static let viewportWidth: CGFloat = 360
    public static let viewportHeight: CGFloat = 620
    public static let viewportSize = CGSize(width: viewportWidth, height: viewportHeight)
}

private final class ShelfViewportBackgroundNSView: NSView {
    override var isOpaque: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySystemBackground()
    }

    func applySystemBackground() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        layer?.isOpaque = true
    }
}

private struct ShelfViewportBackground: NSViewRepresentable {
    private static let identifier = "scene-shelf-viewport-background"

    init() {}

    func makeNSView(context: Context) -> NSView {
        let view = ShelfViewportBackgroundNSView()
        view.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        view.applySystemBackground()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ShelfViewportBackgroundNSView)?.applySystemBackground()
    }
}

public struct ShelfScrollContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ShelfViewportBackground()
                .frame(
                    width: SceneShelfLayout.viewportWidth,
                    height: SceneShelfLayout.viewportHeight
                )
                .allowsHitTesting(false)
            ScrollView(.vertical) {
                content
                    .frame(width: SceneShelfLayout.viewportWidth, alignment: .topLeading)
            }
            .frame(
                width: SceneShelfLayout.viewportWidth,
                height: SceneShelfLayout.viewportHeight,
                alignment: .topLeading
            )
        }
        .frame(
            width: SceneShelfLayout.viewportWidth,
            height: SceneShelfLayout.viewportHeight,
            alignment: .topLeading
        )
        .clipped()
    }
}
