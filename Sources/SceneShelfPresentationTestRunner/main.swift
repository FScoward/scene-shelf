import AppKit
import Foundation
import SceneShelfAccessibility
import SceneShelfCore
import SceneShelfPresentation
import SwiftUI

@MainActor
private final class HitRecordingWindow: NSWindow {
    var menuHitView: NSView?
    private(set) var lastMouseDownHit: NSView?
    private var suppressingMenuClick = false

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown || event.type == .leftMouseUp else {
            super.sendEvent(event)
            return
        }

        let hit = contentView.flatMap {
            $0.hitTest($0.convert(event.locationInWindow, from: nil))
        }
        if event.type == .leftMouseDown {
            lastMouseDownHit = hit
            if hit === menuHitView {
                suppressingMenuClick = true
                return
            }
        } else if suppressingMenuClick {
            suppressingMenuClick = false
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class ActivationRecorder {
    private(set) var activationCount = 0

    func recordActivation() {
        activationCount += 1
    }
}

@main
@MainActor
struct SceneShelfPresentationTestRunner {
    static func main() {
        let panel = SceneShelfPanel(
            contentRect: NSRect(origin: .zero, size: SceneShelfLayout.viewportSize),
            increaseContrast: false
        )

        runTest {
            expect(
                panel.styleMask.contains(.borderless),
                "menu bar shelf keeps a borderless panel"
            )
        }
        runTest {
            expect(
                !panel.styleMask.contains(.nonactivatingPanel),
                "menu bar shelf uses an activating panel for direct interaction"
            )
        }
        runTest {
            expect(
                panel.canBecomeKey,
                "shelf panel must accept key focus for TextField editing"
            )
        }
        runTest {
            expect(
                !panel.canBecomeMain,
                "shelf panel must remain an accessory panel, not a main window"
            )
        }
        runTest {
            expect(
                panel.appearance?.name == .darkAqua,
                "shelf panel uses the darkAqua appearance"
            )
        }
        runTest(testPanelHighContrastAppearance)
        runTest(testFailureMessageFormat)
        runTest(testSavedScenePreviewNormalization)
        runTest(testSavedScenePreviewCollectionIsKeyedBySceneID)
        runTest(testLongContentLayout)
        runTest(testShelfViewportMaterialSurface)
        runTest(testShelfRootClipSurface)
        runTest(testReadableContentSurfacePresentation)
        runTest(testLiquidGlassSurfaceAndPolicy)
        runTest(testPrimaryButtonDisabledInteraction)
        runTest(testPanelScrollOperation)
        runTest(testShelfActivation)
        runTest(testPrimaryCardHitArea)
        runTest(testStageManagerPreviewCardBoundary)
        runTest(testAXReasonPresentationBoundary)
        runTest(testCleanupFailureRefreshBoundary)
        runTest(testPersistenceDiagnosticPresentationBoundary)
        runTest(testApplicationCatalogPresentationBoundary)
        runTest(testApplicationCatalogWindowRowsAndPermissionRevocation)
        runTest(testApplicationCatalogSelectionPresentation)
        runTest(testThumbnailPresentationUsesRealImageBeforeFallback)

        if failures == 0 {
            print("SceneShelfPresentationTestRunner: \(executedTests) tests passed")
        } else {
            print("SceneShelfPresentationTestRunner: \(failures) failures across \(executedTests) tests")
            Foundation.exit(1)
        }
    }

    private static var failures = 0
    private static var executedTests = 0

    private static func runTest(_ body: () -> Void) {
        executedTests += 1
        body()
    }

    private static func testFailureMessageFormat() {
        let main = SceneWindowIdentity(
            bundleIdentifier: SceneMatcher.fixtureBundleIdentifier,
            processID: 101,
            title: "Main",
            identifier: "main"
        )
        let secondary = SceneWindowIdentity(
            bundleIdentifier: SceneMatcher.fixtureBundleIdentifier,
            processID: 101,
            title: "Secondary",
            identifier: "secondary"
        )
        let report = SceneRestoreReport(
            sceneID: "scene-format",
            action: .display,
            outcomes: [
                .failed(target: main, reason: .ambiguousMatch),
                .failed(target: secondary, reason: .windowMissing)
            ]
        )
        let expected = "Main: 対象ウィンドウを一意に特定できません\nSecondary: 対象ウィンドウが見つかりません"
        expect(
            SceneFailureMessageFormatter.format(report) == expected,
            "failure reasons keep target order and use one line per target"
        )
    }

    private static func testLongContentLayout() {
        let hosting = NSHostingView(
            rootView: ShelfScrollContainer {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<80, id: \.self) { index in
                        Text("Fixture row \(index)")
                            .frame(height: 24)
                    }
                }
            }
        )
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: SceneShelfLayout.viewportWidth,
            height: SceneShelfLayout.viewportHeight
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: SceneShelfLayout.viewportSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.contentView?.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        let scrollView = descendants(of: hosting).compactMap { $0 as? NSScrollView }.first
        let viewportHeight = scrollView?.frame.height ?? 0
        let documentHeight = scrollView?.documentView?.frame.height ?? 0
        let contentHeight = scrollView?.contentSize.height ?? 0
        expect(
            viewportHeight <= SceneShelfLayout.viewportHeight,
            "scroll viewport stays within the 620 point panel height"
        )
        expect(
            documentHeight > contentHeight,
            "long shelf content is taller than its scroll viewport"
        )
    }

    private static func testSavedScenePreviewNormalization() {
        let mainIdentity = SceneWindowIdentity(
            bundleIdentifier: "com.example.editor",
            processID: 701,
            title: "Main",
            identifier: "main"
        )
        let secondaryIdentity = SceneWindowIdentity(
            bundleIdentifier: "com.example.editor",
            processID: 701,
            title: "Secondary",
            identifier: "secondary"
        )
        let empty = SceneShelfPreviewPresentation.preview(
            for: SavedScene(id: "empty", name: "空", windows: [])
        )
        expect(empty.windows.isEmpty, "empty saved scene produces an empty preview")

        let single = SceneShelfPreviewPresentation.preview(
            for: SavedScene(
                id: "single",
                name: "単一",
                windows: [
                    SceneWindowSnapshot(
                        identity: mainIdentity,
                        frame: SceneFrame(x: 120, y: 140, width: 800, height: 600),
                        isMinimized: false
                    )
                ]
            )
        )
        expect(
            single.windows.first?.frame == SceneShelfPreviewFrame(x: 0, y: 0, width: 1, height: 1),
            "single window fills the normalized preview union"
        )

        let multiple = SceneShelfPreviewPresentation.preview(
            for: SavedScene(
                id: "multiple",
                name: "複数",
                windows: [
                    SceneWindowSnapshot(
                        identity: mainIdentity,
                        frame: SceneFrame(x: -100, y: -50, width: 300, height: 200),
                        isMinimized: false
                    ),
                    SceneWindowSnapshot(
                        identity: secondaryIdentity,
                        frame: SceneFrame(x: 300, y: 150, width: 100, height: 100),
                        isMinimized: false
                    )
                ]
            )
        )
        expect(
            multiple.windows.map(\.frame) == [
                SceneShelfPreviewFrame(x: 0, y: 0, width: 0.6, height: 2.0 / 3.0),
                SceneShelfPreviewFrame(x: 0.8, y: 2.0 / 3.0, width: 0.2, height: 1.0 / 3.0)
            ],
            "multiple windows use one union basis including negative coordinates"
        )
        let aspectPreview = SceneShelfPreviewPresentation.preview(
            for: SavedScene(
                id: "aspect",
                name: "比率",
                windows: [
                    SceneWindowSnapshot(
                        identity: mainIdentity,
                        frame: SceneFrame(x: 0, y: 0, width: 300, height: 200),
                        isMinimized: false
                    )
                ]
            )
        )
        let aspectFit = SceneShelfPreviewPresentation.contentRect(
            for: aspectPreview,
            in: CGSize(width: 100, height: 70)
        )
        expect(
            abs(aspectFit.width / aspectFit.height - 1.5) < 0.0001,
            "thumbnail aspect-fit preserves a 300x200 window ratio"
        )

        let zeroSize = SceneShelfPreviewPresentation.preview(
            for: SavedScene(
                id: "zero",
                name: "ゼロ",
                windows: [
                    SceneWindowSnapshot(
                        identity: mainIdentity,
                        frame: SceneFrame(x: 20, y: 30, width: 0, height: 0),
                        isMinimized: false
                    )
                ]
            )
        )
        expect(
            zeroSize.windows.allSatisfy { $0.frame.isFinite && $0.frame.isUnitRange },
            "zero-size windows produce finite normalized bounds"
        )
    }

    private static func testSavedScenePreviewCollectionIsKeyedBySceneID() {
        let window = SceneWindowSnapshot(
            identity: SceneWindowIdentity(
                bundleIdentifier: "com.example.editor",
                processID: 702,
                title: "Main",
                identifier: "main"
            ),
            frame: SceneFrame(x: 0, y: 0, width: 200, height: 100),
            isMinimized: false
        )
        let scenes = [
            SavedScene(id: "scene-a", name: "A", windows: [window]),
            SavedScene(id: "scene-b", name: "B", windows: [])
        ]
        let previews = SceneShelfPreviewPresentation.previews(for: scenes)
        expect(
            Set(previews.keys) == Set(["scene-a", "scene-b"]),
            "preview collection publishes one entry per saved scene ID"
        )
        expect(
            previews["scene-a"]?.windows.count == 1 && previews["scene-b"]?.windows.isEmpty == true,
            "preview collection preserves each scene's window contents"
        )
    }

    private static func testShelfViewportMaterialSurface() {
        let hosting = NSHostingView(
            rootView: ShelfScrollContainer {
                Color.clear
                    .frame(width: SceneShelfLayout.viewportWidth, height: 1)
            }
        )
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: SceneShelfLayout.viewportWidth,
            height: SceneShelfLayout.viewportHeight
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: SceneShelfLayout.viewportSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
        panel.contentView?.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        guard let background = descendants(of: hosting).first(where: {
            $0.identifier?.rawValue == "scene-shelf-viewport-background"
        }) as? NSVisualEffectView else {
            expect(false, "shelf viewport renders a discoverable visual effect view")
            return
        }

        expect(
            background.frame.width >= SceneShelfLayout.viewportWidth
                && background.frame.height >= SceneShelfLayout.viewportHeight,
            "shelf viewport material covers the full fixed viewport"
        )
        expect(
            background.material == .hudWindow
                && background.blendingMode == .behindWindow
                && background.state == .active,
            "shelf viewport uses active behind-window hud material"
        )
        expect(
            !panel.isOpaque && panel.backgroundColor?.isEqual(NSColor.clear) == true,
            "transparent shelf panel keeps the viewport material visible"
        )
        expect(
            background.hitTest(NSPoint(x: 10, y: 10)) == nil,
            "shelf viewport material does not intercept clicks"
        )
        expect(
            background.layer?.cornerCurve == .continuous
                && background.layer?.masksToBounds == true,
            "shelf viewport material clips to a continuous rounded outer edge"
        )
    }

    private static func testShelfRootClipSurface() {
        let hosting = NSHostingView(
            rootView: ShelfScrollContainer {
                Color.red
                    .frame(
                        width: SceneShelfLayout.viewportWidth,
                        height: SceneShelfLayout.viewportHeight
                    )
            }
        )
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: SceneShelfLayout.viewportWidth,
            height: SceneShelfLayout.viewportHeight
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: SceneShelfLayout.viewportSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hosting
        panel.contentView?.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            expect(false, "shelf root exposes a rendered bitmap for clip observation")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let cornerAlpha = bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1
        expect(
            cornerAlpha < 0.2,
            "shelf root clips rendered scroll content to a continuous rounded boundary"
        )
    }

    private static func testLiquidGlassSurfaceAndPolicy() {
        let nativeCard = SceneShelfGlassPresentation.renderingConfiguration(
            for: .card,
            version: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            reduceTransparency: false,
            increasedContrast: false
        )
        expect(
            nativeCard.platform == .nativeGlass
                && nativeCard.surface == .clear
                && nativeCard.isInteractive
                && nativeCard.outlineOpacity == 0.14
                && nativeCard.button == .glass,
            "native card config uses clear interactive glass with a light outline"
        )

        let nativeReduced = SceneShelfGlassPresentation.renderingConfiguration(
            for: .card,
            version: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            reduceTransparency: true,
            increasedContrast: false
        )
        expect(
            nativeReduced.surface == .regular
                && nativeReduced.isInteractive
                && nativeReduced.outlineOpacity == 0.45
                && nativeReduced.button == .glass,
            "reduced transparency uses regular interactive glass with a strong outline"
        )

        let nativeHighContrast = SceneShelfGlassPresentation.renderingConfiguration(
            for: .header,
            version: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            reduceTransparency: false,
            increasedContrast: true
        )
        expect(
            nativeHighContrast.platform == .nativeGlass
                && nativeHighContrast.surface == .regular
                && !nativeHighContrast.isInteractive
                && nativeHighContrast.outlineOpacity == 0.45
                && nativeHighContrast.button == .glass,
            "increased contrast uses regular header glass with a strong outline"
        )

        let fallbackHeader = SceneShelfGlassPresentation.renderingConfiguration(
            for: .header,
            version: OperatingSystemVersion(majorVersion: 25, minorVersion: 0, patchVersion: 0),
            reduceTransparency: false,
            increasedContrast: false
        )
        expect(
            fallbackHeader.platform == .materialFallback
                && fallbackHeader.surface == .clear
                && !fallbackHeader.isInteractive
                && fallbackHeader.outlineOpacity == 0.14
                && fallbackHeader.button == .bordered,
            "pre-macOS 26 uses the material and bordered fallback"
        )

        var activations = 0
        let hosting = NSHostingView(
            rootView: VStack(alignment: .leading, spacing: 8) {
                Text("Scene Shelf")
                    .frame(width: 240, height: 24, alignment: .leading)
                    .sceneShelfGlassSurface(.header)
                Button {
                    activations += 1
                } label: {
                    SceneShelfCardPrimaryLabel {
                        Text("Card")
                    }
                    .frame(width: 180, height: 44, alignment: .leading)
                    .sceneShelfGlassSurface(.card)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 260, height: 100, alignment: .topLeading)
        )
        let expectedSize = CGSize(width: 260, height: 100)
        hosting.frame = NSRect(origin: .zero, size: expectedSize)
        hosting.layoutSubtreeIfNeeded()

        expect(
            hosting.frame.size == expectedSize,
            "glass header and card preserve the fixed layout size"
        )

        let window = HitRecordingWindow(
            contentRect: NSRect(origin: .zero, size: expectedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        sendClick(to: window, at: NSPoint(x: 80, y: 58))

        expect(
            activations == 1,
            "glass card keeps its click action"
        )
        window.orderOut(nil)
    }

    private static func testReadableContentSurfacePresentation() {
        expect(
            SceneShelfReadableContentSurfacePresentation.backgroundOpacity(
                reduceTransparency: false
            ) == 0.88,
            "readable content surface keeps a translucent system background by default"
        )
        expect(
            SceneShelfReadableContentSurfacePresentation.backgroundOpacity(
                reduceTransparency: true
            ) == 1.0,
            "readable content surface becomes opaque when transparency is reduced"
        )

        var activations = 0
        let hosting = NSHostingView(
            rootView: GroupBox {
                Button {
                    activations += 1
                } label: {
                    SceneShelfCardPrimaryLabel {
                        Text("Readable")
                    }
                }
                .buttonStyle(.plain)
            }
            .sceneShelfReadableContentSurface()
            .accessibilityIdentifier("application-catalog-read-only")
            .frame(width: 240, height: 72, alignment: .topLeading)
        )
        let expectedSize = CGSize(width: 240, height: 72)
        hosting.frame = NSRect(origin: .zero, size: expectedSize)
        hosting.layoutSubtreeIfNeeded()
        expect(
            hosting.frame.size == expectedSize,
            "readable content surface preserves its fixed layout"
        )

        let window = HitRecordingWindow(
            contentRect: NSRect(origin: .zero, size: expectedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        sendClick(to: window, at: NSPoint(x: 80, y: 30))
        expect(
            activations == 1,
            "readable content surface preserves the embedded click action"
        )
        window.orderOut(nil)
    }

    private static func testPanelScrollOperation() {
        let panel = SceneShelfPanel(
            contentRect: NSRect(origin: .zero, size: SceneShelfLayout.viewportSize)
        )
        let hosting = NSHostingView(
            rootView: ShelfScrollContainer {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<80, id: \.self) { index in
                        Text("Fixture row \(index)")
                            .frame(height: 24)
                    }
                }
            }
        )
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: SceneShelfLayout.viewportWidth,
            height: SceneShelfLayout.viewportHeight
        )
        panel.contentView = hosting
        panel.contentView?.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        guard let scrollView = descendants(of: hosting)
            .compactMap({ $0 as? NSScrollView })
            .first else {
            expect(false, "long shelf panel exposes a scroll view")
            return
        }

        guard let documentView = scrollView.documentView else {
            expect(false, "long shelf panel exposes a scroll document")
            return
        }

        let before = scrollView.documentVisibleRect.minY
        let targetY = max(
            0,
            documentView.bounds.height - scrollView.contentSize.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()
        let after = scrollView.documentVisibleRect.minY

        expect(
            !panel.styleMask.contains(.nonactivatingPanel),
            "shelf panel must be activating so scroll input reaches its content"
        )
        expect(
            after > before,
            "scroll operation changes the visible scroll position"
        )
    }

    private static func testShelfActivation() {
        let recorder = ActivationRecorder()
        let panel = SceneShelfPanel(
            contentRect: NSRect(origin: .zero, size: SceneShelfLayout.viewportSize),
            activateApplication: {
                recorder.recordActivation()
            }
        )

        expect(
            recorder.activationCount == 0,
            "activation collaborator starts untouched"
        )

        panel.showShelf()

        expect(
            recorder.activationCount == 1,
            "showShelf activates the accessory application before presentation"
        )
        expect(
            panel.isVisible,
            "showShelf presents the keyable shelf panel"
        )
        panel.orderOut(nil)
    }

    private static func testPanelHighContrastAppearance() {
        let panel = SceneShelfPanel(
            contentRect: NSRect(origin: .zero, size: SceneShelfLayout.viewportSize),
            increaseContrast: true
        )
        expect(
            panel.appearance?.name == .darkAqua
                && panel.configuredAppearanceName == .accessibilityHighContrastDarkAqua,
            "increased contrast selects the high contrast darkAqua appearance"
        )
        panel.orderOut(nil)
    }

    private static func testPrimaryButtonDisabledInteraction() {
        let expectedSize = CGSize(width: 220, height: 52)
        var disabledActivations = 0
        let disabledHosting = NSHostingView(
            rootView: Button("主要操作") {
                disabledActivations += 1
            }
            .sceneShelfGlassPrimaryButtonStyle()
            .disabled(true)
            .frame(width: expectedSize.width, height: expectedSize.height)
        )
        disabledHosting.frame = NSRect(origin: .zero, size: expectedSize)
        disabledHosting.layoutSubtreeIfNeeded()
        let disabledWindow = HitRecordingWindow(
            contentRect: NSRect(origin: .zero, size: expectedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        disabledWindow.appearance = NSAppearance(named: .darkAqua)
        disabledWindow.contentView = disabledHosting
        disabledWindow.makeKeyAndOrderFront(nil)
        disabledWindow.displayIfNeeded()
        disabledHosting.layoutSubtreeIfNeeded()
        sendClick(to: disabledWindow, at: NSPoint(x: 110, y: 26))
        expect(
            disabledActivations == 0,
            "disabled major glass button does not activate"
        )
        disabledWindow.orderOut(nil)

        var enabledActivations = 0
        let enabledHosting = NSHostingView(
            rootView: Button("主要操作") {
                enabledActivations += 1
            }
            .sceneShelfGlassPrimaryButtonStyle()
            .frame(width: expectedSize.width, height: expectedSize.height)
        )
        enabledHosting.frame = NSRect(origin: .zero, size: expectedSize)
        enabledHosting.layoutSubtreeIfNeeded()
        let enabledWindow = HitRecordingWindow(
            contentRect: NSRect(origin: .zero, size: expectedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        enabledWindow.appearance = NSAppearance(named: .darkAqua)
        enabledWindow.contentView = enabledHosting
        enabledWindow.makeKeyAndOrderFront(nil)
        enabledWindow.displayIfNeeded()
        enabledHosting.layoutSubtreeIfNeeded()
        sendClick(to: enabledWindow, at: NSPoint(x: 110, y: 26))
        expect(
            enabledActivations == 1,
            "enabled major glass button keeps its activation"
        )
        enabledWindow.orderOut(nil)
    }

    private static func testPrimaryCardHitArea() {
        var primaryActivations = 0
        let hosting = NSHostingView(
            rootView: HStack(spacing: 4) {
                Button {
                    primaryActivations += 1
                } label: {
                    SceneShelfCardPrimaryLabel {
                        Text("検証A")
                    }
                }
                .buttonStyle(.plain)
                Menu {
                    Button("管理") {}
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
            }
            .frame(width: 300, height: 60, alignment: .leading)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        hosting.layoutSubtreeIfNeeded()

        let window = HitRecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        let primaryWhitespaceHit = hosting.hitTest(NSPoint(x: 220, y: 30))
        let menuHit = hosting.hitTest(NSPoint(x: 285, y: 30))
        window.menuHitView = menuHit

        expect(
            hosting.fittingSize.height >= 44,
            "saved scene primary card keeps a 44 point minimum hit height"
        )
        expect(
            primaryWhitespaceHit != nil,
            "saved scene primary card accepts clicks across its visual whitespace"
        )
        expect(
            menuHit != nil,
            "saved scene management menu remains independently hit-testable"
        )

        sendClick(to: window, at: NSPoint(x: 220, y: 30))
        expect(
            primaryActivations == 1,
            "saved scene primary whitespace click invokes its action exactly once"
        )

        sendClick(to: window, at: NSPoint(x: 285, y: 30))
        expect(
            window.lastMouseDownHit === menuHit,
            "saved scene management menu receives the menu-area AppKit event"
        )
        expect(
            primaryActivations == 1,
            "saved scene management menu click does not invoke the primary action"
        )
        window.orderOut(nil)
    }

    private static func testStageManagerPreviewCardBoundary() {
        let preview = SceneShelfPreviewPresentation.preview(
            for: SavedScene(id: "scene-card", name: "検証A", windows: [])
        )
        let hosting = NSHostingView(
            rootView: HStack(spacing: 4) {
                Button {} label: {
                    SceneShelfCardPrimaryLabel {
                        HStack(spacing: 10) {
                            SceneShelfPreviewThumbnail(preview: preview)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("検証A")
                                Text(SceneState.stashed.japaneseLabel)
                            }
                            Spacer()
                        }
                    }
                }
                .buttonStyle(.plain)
                Menu { Button("管理") {} } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
            }
            .frame(width: 300, height: 76, alignment: .leading)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 76)
        hosting.layoutSubtreeIfNeeded()

        let primaryHit = hosting.hitTest(NSPoint(x: 220, y: 38))
        let menuHit = hosting.hitTest(NSPoint(x: 285, y: 38))
        expect(primaryHit != nil, "preview card keeps the primary whitespace clickable")
        expect(menuHit != nil, "preview card keeps an independent ellipsis hit area")
    }

    private static func testAXReasonPresentationBoundary() {
        let target = SceneWindowIdentity(
            bundleIdentifier: SceneMatcher.fixtureBundleIdentifier,
            processID: 101,
            title: "Main",
            identifier: "main"
        )
        let plan = SceneRestorePlan(
            sceneID: "scene-reason",
            action: .display,
            instructions: [
                SceneRestoreInstruction(
                    target: target,
                    frame: SceneFrame(x: 1, y: 2, width: 3, height: 4),
                    operations: [.unminimize, .move, .resize]
                )
            ]
        )

        for reason in [
            FailureReason.permissionDenied,
            FailureReason.applicationUnavailable,
            FailureReason.ambiguousMatch
        ] {
            let discovery = AXWindowDiscoveryResult.failure(reason)
            expect(
                SceneShelfAXPresentation.discoveryMessage(for: discovery) == reason.japaneseLabel,
                "discovery failure keeps its Japanese reason"
            )
            expect(
                SceneShelfAXPresentation.saveFailureMessage(
                    for: .discoveryFailed(reason)
                ) == "保存対象を取得できないため、保存を中止しました: \(reason.japaneseLabel)",
                "save failure uses the shared Japanese reason boundary"
            )
            expect(
                SceneShelfAXPresentation.overwriteFailureMessage(for: reason)
                    == "現在の配置を取得できません: \(reason.japaneseLabel)",
                "overwrite failure uses the shared Japanese reason boundary"
            )
            let report = SceneShelfAXPresentation.restoreReport(
                for: plan,
                discoveryFailure: reason
            )
            expect(
                SceneFailureMessageFormatter.format(report)
                    == "Main: \(SceneFailureReason(rawValue: reason.rawValue)?.japaneseLabel ?? "")",
                "restore failure uses the shared Japanese reason boundary"
            )
        }
    }

    private static func testCleanupFailureRefreshBoundary() {
        let cleanupFailure = SceneManagementError.cleanupFailed("scene-cleanup")
        expect(
            SceneShelfManagementPresentation.message(for: cleanupFailure)
                == cleanupFailure.japaneseLabel,
            "cleanup failure keeps the warning that deletion was already applied"
        )
        expect(
            SceneShelfManagementPresentation.shouldRefreshAfterDeleteFailure(cleanupFailure),
            "cleanup failure requests a store refresh after the delete"
        )

        let activeFailure = SceneManagementError.sceneActive("scene-active")
        expect(
            !SceneShelfManagementPresentation.shouldRefreshAfterDeleteFailure(activeFailure),
            "non-cleanup delete failures do not refresh as if the record were removed"
        )

        let unsupportedOverwrite = SceneManagementError.applicationOverwriteUnsupported
        expect(
            SceneShelfManagementPresentation.message(for: unsupportedOverwrite)
                .contains("一般アプリ配置の上書きは未対応"),
            "generic overwrite keeps an explicit Japanese unsupported message"
        )
    }

    private static func testPersistenceDiagnosticPresentationBoundary() {
        let diagnostics = [
            ScenePersistenceDiagnostic(
                kind: .missingRevision,
                sceneID: "scene-missing",
                path: "/tmp/scene-missing-1.json",
                detail: "revision file is missing"
            ),
            ScenePersistenceDiagnostic(
                kind: .corruptRevision,
                sceneID: "scene-corrupt",
                path: "/tmp/scene-corrupt-1.json",
                detail: "revision JSON could not be decoded"
            )
        ]
        let rows = SceneShelfPersistencePresentation.rows(for: diagnostics)

        expect(
            rows.map(\.sceneID) == ["scene-missing", "scene-corrupt"],
            "persistence diagnostics preserve the affected scene IDs"
        )
        expect(
            rows[0].message.contains("保存ファイルが見つかりません"),
            "missing revision is presented with a Japanese reason"
        )
        expect(
            rows[1].message.contains("保存ファイルが壊れています"),
            "corrupt revision is presented with a Japanese reason"
        )

        let globalRow = SceneShelfPersistencePresentation.globalRow(
            message: "保存済み配置の一覧を読み込めませんでした"
        )
        expect(
            globalRow.sceneID == "一覧全体" && globalRow.message.contains("読み込めませんでした"),
            "global persistence failure has a safe target and readable reason"
        )

        let hosting = NSHostingView(
            rootView: SceneShelfPersistenceDiagnosticsView(
                rows: rows,
                onReload: {}
            )
        )
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: SceneShelfLayout.viewportWidth,
            height: SceneShelfLayout.viewportHeight
        )
        hosting.layoutSubtreeIfNeeded()
        expect(
            SceneShelfPersistencePresentation.rowLabel(for: rows[0])
                == "対象: scene-missing: 保存ファイルが見つかりません",
            "diagnostic view label renders the scene ID and Japanese reason"
        )
        expect(
            SceneShelfPersistencePresentation.reloadButtonIdentifier == "persistence-reload"
                && hosting.fittingSize.height > 0,
            "diagnostic view exposes a renderable reload control boundary"
        )
    }

    private static func testApplicationCatalogPresentationBoundary() {
        let window = AXWindowSnapshot(
            identity: AXWindowIdentity(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Draft",
                identifier: "draft"
            ),
            frame: AXFrame(x: 20, y: 40, width: 900, height: 700),
            isMinimized: true
        )
        let candidate = AXApplicationCandidate(
            appName: "Text Editor",
            bundleIdentifier: "com.example.Editor",
            processID: 701,
            windows: [window]
        )

        expect(
            SceneShelfApplicationCatalogPresentation.inspectButtonIdentifier
                == "accessibility-inspect-applications",
            "application catalog exposes a stable inspect button identifier"
        )
        expect(
            SceneShelfApplicationCatalogPresentation.readOnlyNotice.contains("読み取り専用")
                && SceneShelfApplicationCatalogPresentation.readOnlyNotice.contains("保存・復元は選択したwindowだけ")
                && SceneShelfApplicationCatalogPresentation.readOnlyNotice.contains("window title/PID")
                && SceneShelfApplicationCatalogPresentation.readOnlyNotice.contains("端末内"),
            "application catalog observation is read-only and only selected windows are persisted/restored"
        )
        let candidateLabel = SceneShelfApplicationCatalogPresentation.candidateLabel(for: candidate)
        expect(
            candidateLabel.contains("Text Editor")
                && candidateLabel.contains("com.example.Editor")
                && candidateLabel.contains("PID 701"),
            "candidate label exposes app identity values"
        )
        let windowLabel = SceneShelfApplicationCatalogPresentation.windowLabel(for: window)
        expect(
            windowLabel.contains("Draft")
                && windowLabel.contains("draft")
                && windowLabel.contains("900×700")
                && windowLabel.contains("最小化"),
            "window label exposes title, identifier, frame, and minimized state"
        )
    }

    private static func testApplicationCatalogWindowRowsAndPermissionRevocation() {
        let duplicateWindowIdentity = AXWindowIdentity(
            bundleIdentifier: "com.example.Editor",
            processID: 702,
            title: "Untitled",
            identifier: nil
        )
        let duplicateWindows = [
            AXWindowSnapshot(
                identity: duplicateWindowIdentity,
                frame: AXFrame(x: 10, y: 20, width: 640, height: 480),
                isMinimized: false
            ),
            AXWindowSnapshot(
                identity: duplicateWindowIdentity,
                frame: AXFrame(x: 30, y: 40, width: 800, height: 600),
                isMinimized: true
            )
        ]
        let candidate = AXApplicationCandidate(
            appName: "Text Editor",
            bundleIdentifier: "com.example.Editor",
            processID: 702,
            windows: duplicateWindows
        )
        let rows = SceneShelfApplicationCatalogPresentation.windowRows(for: candidate)
        expect(rows.count == 2, "duplicate window observations remain visible as two rows")
        expect(Set(rows.map(\.id)).count == 2, "window row IDs include a stable index")
        expect(rows[0].label != rows[1].label, "duplicate window rows retain distinct value details")
        expect(rows.allSatisfy { !$0.isSelectable }, "duplicate window rows are not selectable")
        expect(
            rows.allSatisfy {
                SceneShelfApplicationCatalogPresentation.selectionLabel(for: $0)
                    .contains("一意に識別できないため保存対象にできません")
            },
            "duplicate window rows explain that they cannot become save targets"
        )
        expect(
            SceneShelfApplicationCatalogPresentation.selectableWindowIDs(from: candidate).isEmpty,
            "duplicate identity rows contribute no selectable identity"
        )

        let granted = SceneShelfApplicationCatalogPresentation.catalogState(
            permission: .granted,
            result: .success([candidate])
        )
        expect(granted.candidates == [candidate], "granted catalog state exposes candidates")
        let revoked = SceneShelfApplicationCatalogPresentation.catalogState(
            permission: .denied,
            result: nil
        )
        expect(revoked.candidates.isEmpty, "permission revocation clears catalog candidates")
        expect(revoked.message.contains("権限が取り消された"), "revocation message names permission cancellation")
        let failedCatalog = SceneShelfApplicationCatalogPresentation.catalogState(
            permission: .granted,
            result: .failure(.permissionDenied)
        )
        expect(failedCatalog.candidates.isEmpty, "catalog failure clears candidates")
        expect(failedCatalog.message.contains("権限"), "catalog failure keeps a Japanese permission reason")
        expect(
            SceneShelfApplicationCatalogPresentation.selectedWindowIDs(
                existing: [duplicateWindowIdentity],
                from: failedCatalog
            ).isEmpty,
            "catalog failure clears the selection set"
        )
    }

    private static func testApplicationCatalogSelectionPresentation() {
        let window = AXWindowSnapshot(
            identity: AXWindowIdentity(
                bundleIdentifier: "com.example.Editor",
                processID: 703,
                title: "Draft",
                identifier: "draft"
            ),
            frame: AXFrame(x: 0, y: 0, width: 640, height: 480),
            isMinimized: false
        )
        let candidate = AXApplicationCandidate(
            appName: "Text Editor",
            bundleIdentifier: "com.example.Editor",
            processID: 703,
            windows: [window]
        )
        let row = SceneShelfApplicationCatalogPresentation.windowRows(for: candidate)[0]
        expect(
            SceneShelfApplicationCatalogPresentation.nameFieldIdentifier == "application-scene-name"
                && SceneShelfApplicationCatalogPresentation.saveButtonIdentifier == "application-save-scene",
            "application selection exposes stable name and save identifiers"
        )
        expect(
            SceneShelfApplicationCatalogPresentation.selectionLabel(for: row).contains("保存対象")
                && SceneShelfApplicationCatalogPresentation.selectionLabel(for: row).contains("Draft"),
            "application selection label explains the saved target in Japanese"
        )
        expect(row.isSelectable, "unique application window row is selectable")
    }

    private static func testThumbnailPresentationUsesRealImageBeforeFallback() {
        let fallback = SceneShelfPreview(sceneID: "scene-thumb", windows: [])
        let missing = SceneShelfThumbnailPresentation.content(
            sceneID: "scene-thumb",
            thumbnailData: [:],
            fallback: fallback
        )
        expect(missing == .fallback(fallback), "missing thumbnail data should keep the existing layout fallback")

        let data = Data("thumbnail".utf8)
        let real = SceneShelfThumbnailPresentation.content(
            sceneID: "scene-thumb",
            thumbnailData: ["scene-thumb": data],
            fallback: fallback
        )
        expect(real == .image(data), "available thumbnail data should cross the UI boundary as a real image")
    }

    private static func sendClick(to window: NSWindow, at point: NSPoint) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ) else {
                continue
            }
            window.sendEvent(event)
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            failures += 1
            print("FAIL: \(message)")
            return
        }
        print("PASS: \(message)")
    }
}
