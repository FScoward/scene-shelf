import SwiftUI

public enum SceneShelfLayout {
    public static let viewportWidth: CGFloat = 360
    public static let viewportHeight: CGFloat = 620
    public static let viewportSize = CGSize(width: viewportWidth, height: viewportHeight)
}

public struct ShelfScrollContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView(.vertical) {
            content
                .frame(width: SceneShelfLayout.viewportWidth, alignment: .topLeading)
        }
        .frame(
            width: SceneShelfLayout.viewportWidth,
            height: SceneShelfLayout.viewportHeight,
            alignment: .topLeading
        )
        .clipped()
    }
}
