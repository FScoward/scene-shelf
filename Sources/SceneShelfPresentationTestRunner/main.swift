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
            contentRect: NSRect(origin: .zero, size: SceneShelfLayout.viewportSize)
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
        runTest(testFailureMessageFormat)
        runTest(testLongContentLayout)
        runTest(testPanelScrollOperation)
        runTest(testShelfActivation)
        runTest(testPrimaryCardHitArea)
        runTest(testAXReasonPresentationBoundary)
        runTest(testCleanupFailureRefreshBoundary)
        runTest(testPersistenceDiagnosticPresentationBoundary)

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
