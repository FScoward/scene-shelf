import SwiftUI

/// Draws saved window rectangles without reading pixels from any application.
public struct SceneShelfPreviewThumbnail: View {
    private let preview: SceneShelfPreview
    private let isDisplayed: Bool

    public init(preview: SceneShelfPreview, isDisplayed: Bool = false) {
        self.preview = preview
        self.isDisplayed = isDisplayed
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.black.opacity(0.14))
                if preview.windows.isEmpty {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                        .padding(13)
                } else {
                    let canvas = SceneShelfPreviewPresentation.contentRect(
                        for: preview,
                        in: geometry.size
                    )
                    ForEach(Array(preview.windows.enumerated()), id: \.offset) { index, window in
                        let frame = thumbnailFrame(
                            for: window.frame,
                            in: canvas.size
                        )
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(windowTint(for: index))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(.white.opacity(0.72), lineWidth: 0.7)
                            )
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: canvas.minX + frame.minX, y: canvas.minY + frame.minY)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isDisplayed ? Color.accentColor : .white.opacity(0.18),
                        lineWidth: isDisplayed ? 2 : 0.7
                    )
                    .allowsHitTesting(false)
            )
        }
        .frame(width: 100, height: 70)
        .accessibilityHidden(true)
    }

    private func thumbnailFrame(
        for frame: SceneShelfPreviewFrame,
        in size: CGSize
    ) -> CGRect {
        let minimumWidth = min(14, size.width)
        let minimumHeight = min(10, size.height)
        let width = min(
            size.width,
            max(minimumWidth, size.width * frame.width)
        )
        let height = min(
            size.height,
            max(minimumHeight, size.height * frame.height)
        )
        let originX = min(
            max(0, size.width * frame.x),
            max(0, size.width - width)
        )
        let originY = min(
            max(0, size.height * frame.y),
            max(0, size.height - height)
        )
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func windowTint(for index: Int) -> Color {
        let opacity = 0.62 + min(Double(index), 3) * 0.06
        return Color.accentColor.opacity(opacity)
    }
}
