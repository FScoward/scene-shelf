import Foundation
import SceneShelfAccessibility

@main
@MainActor
struct SceneShelfAXTestRunner {
    private static var failures = 0
    private static var executedTests = 0

    static func main() async {
        await probeSystemBoundaryIfRequested()
        await run("application catalog permission denied performs zero writes") {
            let adapter = FakeAXAdapter(
                permission: .denied,
                windows: [fixtureWindow()],
                catalogResult: .failure(.permissionDenied)
            )
            let result = await adapter.applicationCatalog()
            if result.failureReason != .permissionDenied {
                fail("catalog reason was \(String(describing: result.failureReason))")
            }
            if !result.candidates.isEmpty {
                fail("denied catalog returned \(result.candidates.count) candidates")
            }
            let writes = await adapter.currentWriteCount()
            if writes != 0 {
                fail("denied catalog performed \(writes) writes")
            }
        }

        await run("application catalog normalization excludes unsafe process classes") {
            let normal = applicationProcess(
                appName: "Text Editor",
                bundleIdentifier: "com.example.Editor",
                processID: 501
            )
            let sameBundleDifferentProcess = applicationProcess(
                appName: "Text Editor",
                bundleIdentifier: "com.example.Editor",
                processID: 502
            )
            let sceneShelf = applicationProcess(
                appName: "Scene Shelf",
                bundleIdentifier: SceneShelfAXContract.sceneShelfBundleIdentifier,
                processID: 503
            )
            let missingBundle = applicationProcess(
                appName: "No Bundle",
                bundleIdentifier: nil,
                processID: 504
            )
            let noUserInterface = applicationProcess(
                appName: "Background Helper",
                bundleIdentifier: "com.example.Helper",
                processID: 505,
                hasUserInterface: false
            )
            let background = applicationProcess(
                appName: "Background Agent",
                bundleIdentifier: "com.example.Agent",
                processID: 506,
                isBackgroundOnly: true
            )

            let candidates = AXApplicationCatalogNormalizer.normalize([
                normal,
                sameBundleDifferentProcess,
                sceneShelf,
                missingBundle,
                noUserInterface,
                background
            ])

            expect(candidates.count == 2)
            expect(candidates.map(\.processID) == [501, 502])
            expect(candidates[0].id != candidates[1].id)
            expect(candidates[0].windows[0].identity.bundleIdentifier == "com.example.Editor")
        }

        await run("application catalog exposes app and window value fields") {
            let process = applicationProcess(
                appName: "Text Editor",
                bundleIdentifier: "com.example.Editor",
                processID: 601,
                window: AXWindowSnapshot(
                    identity: AXWindowIdentity(
                        bundleIdentifier: "com.example.Editor",
                        processID: 601,
                        title: "Draft",
                        identifier: "draft"
                    ),
                    frame: AXFrame(x: 20, y: 40, width: 900, height: 700),
                    isMinimized: true
                )
            )
            let candidate = AXApplicationCatalogNormalizer.normalize([process]).first
            expect(candidate?.appName == "Text Editor")
            expect(candidate?.bundleIdentifier == "com.example.Editor")
            expect(candidate?.processID == 601)
            expect(candidate?.windows.first?.identity.title == "Draft")
            expect(candidate?.windows.first?.identity.identifier == "draft")
            expect(candidate?.windows.first?.frame == AXFrame(x: 20, y: 40, width: 900, height: 700))
            expect(candidate?.windows.first?.isMinimized == true)
        }

        await run("visible general windows isolate Finder and System Settings by exact identity") {
            let displayTarget = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 601,
                title: "Draft",
                identifier: "draft"
            )
            let finder = applicationWindow(
                bundleIdentifier: "com.apple.finder",
                processID: 701,
                title: "Documents",
                identifier: "finder-window"
            )
            let systemSettings = applicationWindow(
                bundleIdentifier: "com.apple.systempreferences",
                processID: 702,
                title: "アクセシビリティ",
                identifier: "accessibility"
            )
            let alreadyMinimized = applicationWindow(
                bundleIdentifier: "com.example.Terminal",
                processID: 703,
                title: "Shell",
                identifier: "shell",
                minimized: true
            )
            let sceneShelf = applicationWindow(
                bundleIdentifier: SceneShelfAXContract.sceneShelfBundleIdentifier,
                processID: 704,
                title: "Scene Shelf",
                identifier: "main"
            )
            let processes = [
                applicationProcess(
                    appName: "Scene Shelf",
                    bundleIdentifier: sceneShelf.identity.bundleIdentifier,
                    processID: sceneShelf.identity.processID,
                    window: sceneShelf
                ),
                applicationProcess(
                    appName: "Draft Editor",
                    bundleIdentifier: displayTarget.identity.bundleIdentifier,
                    processID: displayTarget.identity.processID,
                    window: displayTarget
                ),
                applicationProcess(
                    appName: "Finder",
                    bundleIdentifier: finder.identity.bundleIdentifier,
                    processID: finder.identity.processID,
                    window: finder
                ),
                applicationProcess(
                    appName: "System Settings",
                    bundleIdentifier: systemSettings.identity.bundleIdentifier,
                    processID: systemSettings.identity.processID,
                    window: systemSettings
                ),
                applicationProcess(
                    appName: "Terminal",
                    bundleIdentifier: alreadyMinimized.identity.bundleIdentifier,
                    processID: alreadyMinimized.identity.processID,
                    window: alreadyMinimized
                )
            ]
            let catalog = AXApplicationCatalogNormalizer.normalize(processes)
            let isolated = AXApplicationIsolationPolicy.visibleWindowsToIsolate(
                from: catalog,
                excluding: [displayTarget.identity]
            )
            expect(isolated.map(\.identity) == [finder.identity, systemSettings.identity])
            expect(isolated.allSatisfy { !$0.isMinimized })
            expect(isolated.contains { $0.identity.bundleIdentifier == SceneShelfAXContract.sceneShelfBundleIdentifier } == false)
        }

        await run("isolation coordinator minimizes background windows and restores them after hide") {
            let displayTarget = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 601,
                title: "Draft",
                identifier: "draft"
            )
            let finder = applicationWindow(
                bundleIdentifier: "com.apple.finder",
                processID: 701,
                title: "Documents",
                identifier: "finder-window"
            )
            let systemSettings = applicationWindow(
                bundleIdentifier: "com.apple.systempreferences",
                processID: 702,
                title: "アクセシビリティ",
                identifier: "accessibility"
            )
            let catalog = AXApplicationCatalogResult.success(
                AXApplicationCatalogNormalizer.normalize([
                    applicationProcess(
                        appName: "Draft Editor",
                        bundleIdentifier: displayTarget.identity.bundleIdentifier,
                        processID: displayTarget.identity.processID,
                        window: displayTarget
                    ),
                    applicationProcess(
                        appName: "Finder",
                        bundleIdentifier: finder.identity.bundleIdentifier,
                        processID: finder.identity.processID,
                        window: finder
                    ),
                    applicationProcess(
                        appName: "System Settings",
                        bundleIdentifier: systemSettings.identity.bundleIdentifier,
                        processID: systemSettings.identity.processID,
                        window: systemSettings
                    )
                ])
            )
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [displayTarget, finder, systemSettings],
                catalogResult: catalog
            )
            let coordinator = AXWindowIsolationCoordinator()

            let isolation = await coordinator.isolateBeforeDisplay(
                excluding: [displayTarget.identity],
                adapter: adapter
            )
            expect(isolation.succeeded)
            let retainedAfterIsolation = await coordinator.retainedSnapshots()
            expect(retainedAfterIsolation.map(\.identity) == [
                finder.identity,
                systemSettings.identity
            ])

            let restoreFailures = await coordinator.restoreBackground(adapter: adapter)
            expect(restoreFailures.isEmpty)
            let retainedAfterRestore = await coordinator.retainedSnapshots()
            expect(retainedAfterRestore.isEmpty)
            let requests = await adapter.requests()
            expect(requests.map(\.operations) == [
                [.minimize],
                [.minimize],
                [.unminimize],
                [.unminimize]
            ])
            expect(requests[0].authorizationScope?.allowedTargets == Set([
                finder.identity,
                systemSettings.identity
            ]))
            expect(requests[2].authorizationScope?.allowedTargets == Set([
                finder.identity,
                systemSettings.identity
            ]))
        }

        await run("switch isolation does not unminimize the previous background set") {
            let sceneA = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 601,
                title: "Draft",
                identifier: "draft"
            )
            let sceneB = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 601,
                title: "Review",
                identifier: "review"
            )
            let previousBackground = applicationWindow(
                bundleIdentifier: "com.apple.finder",
                processID: 701,
                title: "Documents",
                identifier: "finder-window"
            )
            let newBackground = applicationWindow(
                bundleIdentifier: "com.apple.systempreferences",
                processID: 702,
                title: "アクセシビリティ",
                identifier: "accessibility"
            )
            let firstCatalog = AXApplicationCatalogNormalizer.normalize([
                applicationProcess(
                    appName: "Draft Editor",
                    bundleIdentifier: sceneA.identity.bundleIdentifier,
                    processID: sceneA.identity.processID,
                    window: sceneA
                ),
                applicationProcess(
                    appName: "Finder",
                    bundleIdentifier: previousBackground.identity.bundleIdentifier,
                    processID: previousBackground.identity.processID,
                    window: previousBackground
                )
            ])
            let firstAdapter = FakeAXAdapter(
                permission: .granted,
                windows: [sceneA, previousBackground],
                catalogResult: .success(firstCatalog)
            )
            let coordinator = AXWindowIsolationCoordinator()
            _ = await coordinator.isolateBeforeDisplay(
                excluding: [sceneA.identity],
                adapter: firstAdapter
            )

            let minimizedPrevious = applicationWindow(
                bundleIdentifier: previousBackground.identity.bundleIdentifier,
                processID: previousBackground.identity.processID,
                title: previousBackground.identity.title,
                identifier: previousBackground.identity.identifier,
                minimized: true
            )
            let secondCatalog = AXApplicationCatalogNormalizer.normalize([
                applicationProcess(
                    appName: "Review Editor",
                    bundleIdentifier: sceneB.identity.bundleIdentifier,
                    processID: sceneB.identity.processID,
                    window: sceneB
                ),
                applicationProcess(
                    appName: "Finder",
                    bundleIdentifier: minimizedPrevious.identity.bundleIdentifier,
                    processID: minimizedPrevious.identity.processID,
                    window: minimizedPrevious
                ),
                applicationProcess(
                    appName: "System Settings",
                    bundleIdentifier: newBackground.identity.bundleIdentifier,
                    processID: newBackground.identity.processID,
                    window: newBackground
                )
            ])
            let secondAdapter = FakeAXAdapter(
                permission: .granted,
                windows: [sceneB, minimizedPrevious, newBackground],
                catalogResult: .success(secondCatalog)
            )
            _ = await coordinator.isolateBeforeDisplay(
                excluding: [sceneB.identity],
                adapter: secondAdapter
            )

            let secondRequests = await secondAdapter.requests()
            expect(secondRequests.map(\.operations) == [[.minimize]])
            expect(secondRequests.first?.target == newBackground.identity)
            let retainedAfterSwitch = await coordinator.retainedSnapshots()
            expect(retainedAfterSwitch.map(\.identity) == [
                previousBackground.identity,
                newBackground.identity
            ])
        }

        await run("already minimized background windows are not retained or restored") {
            let minimized = applicationWindow(
                bundleIdentifier: "com.apple.finder",
                processID: 701,
                title: "Documents",
                identifier: "finder-window",
                minimized: true
            )
            let catalog = AXApplicationCatalogNormalizer.normalize([
                applicationProcess(
                    appName: "Finder",
                    bundleIdentifier: minimized.identity.bundleIdentifier,
                    processID: minimized.identity.processID,
                    window: minimized
                )
            ])
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [minimized],
                catalogResult: .success(catalog)
            )
            let coordinator = AXWindowIsolationCoordinator()
            let isolation = await coordinator.isolateBeforeDisplay(
                excluding: [],
                adapter: adapter
            )
            expect(isolation.succeeded)
            let retained = await coordinator.retainedSnapshots()
            expect(retained.isEmpty)
            let requests = await adapter.requests()
            expect(requests.isEmpty)
            let restoreFailures = await coordinator.restoreBackground(adapter: adapter)
            expect(restoreFailures.isEmpty)
        }

        await run("restore failure keeps the exact background snapshot for retry") {
            let finder = applicationWindow(
                bundleIdentifier: "com.apple.finder",
                processID: 701,
                title: "Documents",
                identifier: "finder-window"
            )
            let catalog = AXApplicationCatalogNormalizer.normalize([
                applicationProcess(
                    appName: "Finder",
                    bundleIdentifier: finder.identity.bundleIdentifier,
                    processID: finder.identity.processID,
                    window: finder
                )
            ])
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [finder],
                candidateSequence: [[finder], [], [finder]],
                catalogResult: .success(catalog)
            )
            let coordinator = AXWindowIsolationCoordinator()
            _ = await coordinator.isolateBeforeDisplay(
                excluding: [],
                adapter: adapter
            )
            let firstRestore = await coordinator.restoreBackground(adapter: adapter)
            expect(firstRestore.map(\.target) == [finder.identity])
            let retainedAfterFailure = await coordinator.retainedSnapshots()
            expect(retainedAfterFailure.map(\.identity) == [finder.identity])

            let retryFailures = await coordinator.restoreBackground(adapter: adapter)
            expect(retryFailures.isEmpty)
            let retainedAfterRetry = await coordinator.retainedSnapshots()
            expect(retainedAfterRetry.isEmpty)
        }

        await run("background isolation failure keeps successful retention for later restore") {
            let sceneTarget = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 601,
                title: "Draft",
                identifier: "draft"
            )
            let finder = applicationWindow(
                bundleIdentifier: "com.apple.finder",
                processID: 701,
                title: "Documents",
                identifier: "finder-window"
            )
            let systemSettings = applicationWindow(
                bundleIdentifier: "com.apple.systempreferences",
                processID: 702,
                title: "アクセシビリティ",
                identifier: "accessibility"
            )
            let catalog = AXApplicationCatalogNormalizer.normalize([
                applicationProcess(
                    appName: "Draft Editor",
                    bundleIdentifier: sceneTarget.identity.bundleIdentifier,
                    processID: sceneTarget.identity.processID,
                    window: sceneTarget
                ),
                applicationProcess(
                    appName: "Finder",
                    bundleIdentifier: finder.identity.bundleIdentifier,
                    processID: finder.identity.processID,
                    window: finder
                ),
                applicationProcess(
                    appName: "System Settings",
                    bundleIdentifier: systemSettings.identity.bundleIdentifier,
                    processID: systemSettings.identity.processID,
                    window: systemSettings
                )
            ])
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [sceneTarget, finder, systemSettings],
                candidateSequence: [[sceneTarget, finder], []],
                catalogResult: .success(catalog)
            )
            let coordinator = AXWindowIsolationCoordinator()
            let isolation = await coordinator.isolateBeforeDisplay(
                excluding: [sceneTarget.identity],
                adapter: adapter
            )
            expect(isolation.succeeded == false)
            expect(isolation.failures.map(\.target) == [systemSettings.identity])
            let retained = await coordinator.retainedSnapshots()
            expect(retained.map(\.identity) == [finder.identity])

            let restoreFailures = await coordinator.restoreBackground(adapter: adapter)
            expect(restoreFailures.isEmpty)
            let remaining = await coordinator.retainedSnapshots()
            expect(remaining.isEmpty)
        }

        await run("selected application authorization rejects an unselected target") {
            let selected = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Draft",
                identifier: "draft"
            )
            let unselected = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Notes",
                identifier: "notes"
            )
            let scope = AXAuthorizationScope(allowedTargets: [selected.identity])
            expect(
                AXAuthorizationPolicy.authorize(
                    target: selected.identity,
                    scope: scope
                ) == .authorized
            )
            expect(
                AXAuthorizationPolicy.authorize(
                    target: unselected.identity,
                    scope: scope
                ) == .targetNotAuthorized
            )
        }

        await run("generic application matcher rejects ambiguous nil identifiers") {
            let first = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Untitled",
                identifier: nil
            )
            let second = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Untitled",
                identifier: nil,
                frame: AXFrame(x: 40, y: 50, width: 700, height: 500)
            )
            let decision = AXApplicationSafetyPolicy.resolve(
                target: first.identity,
                candidates: [first, second]
            )
            expect(decision == .ambiguous)

            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [first, second]
            )
            let report = await adapter.perform(
                request(
                    for: first.identity,
                    scope: AXAuthorizationScope(allowedTargets: [first.identity])
                )
            )
            expect(report.failureReason == .ambiguousMatch)
            expect(report.writesPerformed == 0)
            let writes = await adapter.currentWriteCount()
            expect(writes == 0)
        }

        await run("generic application perform resolves each operation and rejects PID reuse") {
            let target = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Draft",
                identifier: "draft"
            )
            let changed = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Renamed",
                identifier: "draft"
            )
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [target],
                candidateSequence: [[target], [changed]]
            )
            let report = await adapter.perform(
                AXOperationRequest(
                    target: target.identity,
                    frame: AXFrame(x: 120, y: 140, width: 800, height: 600),
                    operations: [.move, .resize],
                    authorizationScope: AXAuthorizationScope(
                        allowedTargets: [target.identity]
                    )
                )
            )
            expect(report.failureReason == .windowChanged)
            expect(report.appliedOperations == [.move])
            expect(report.writesPerformed == 1)

            let pidReused = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 702,
                title: "Draft",
                identifier: "draft"
            )
            let reusedAdapter = FakeAXAdapter(
                permission: .granted,
                windows: [pidReused]
            )
            let reusedReport = await reusedAdapter.perform(
                request(
                    for: target.identity,
                    scope: AXAuthorizationScope(allowedTargets: [target.identity])
                )
            )
            expect(reusedReport.failureReason == .pidReused)
            expect(reusedReport.writesPerformed == 0)
        }

        await run("generic authorization rejects a wrong target before any write") {
            let selected = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Draft",
                identifier: "draft"
            )
            let wrongTarget = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Notes",
                identifier: "notes"
            )
            let adapter = FakeAXAdapter(permission: .granted, windows: [selected])
            let report = await adapter.perform(
                request(
                    for: wrongTarget.identity,
                    scope: AXAuthorizationScope(allowedTargets: [selected.identity])
                )
            )
            expect(report.failureReason == .targetNotAuthorized)
            expect(report.writesPerformed == 0)
            let writes = await adapter.currentWriteCount()
            expect(writes == 0)
        }

        await run("generic restore discovery groups each app and process once") {
            let first = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Draft",
                identifier: "draft"
            )
            let sameProcess = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Notes",
                identifier: "notes"
            )
            let secondApplication = applicationWindow(
                bundleIdentifier: "com.example.Terminal",
                processID: 701,
                title: "Shell",
                identifier: "shell"
            )
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [first, sameProcess, secondApplication]
            )
            let targets = [first.identity, sameProcess.identity, secondApplication.identity]
            let processIdentities = AXApplicationDiscovery.uniqueProcessIdentities(from: targets)
            for process in processIdentities {
                let target = targets.first {
                    $0.bundleIdentifier == process.bundleIdentifier
                        && $0.processID == process.processID
                }!
                _ = await adapter.windowResult(for: target)
            }
            if processIdentities.count != 2 {
                fail("expected two process identities, got \(processIdentities.count)")
            }
            let discoveryCount = await adapter.windowDiscoveryCount()
            if discoveryCount != 2 {
                fail("expected two discovery calls, got \(discoveryCount)")
            }
        }

        await run("permission denied performs zero writes") {
            let adapter = FakeAXAdapter(permission: .denied, windows: [fixtureWindow()])
            let report = await adapter.perform(request(for: fixtureIdentity()))
            expect(report.failureReason == .permissionDenied)
            expect(report.writesPerformed == 0)
            let writes = await adapter.currentWriteCount()
            expect(writes == 0)
        }

        await run("non-fixture bundle is rejected before writes") {
            let adapter = FakeAXAdapter(permission: .granted, windows: [fixtureWindow()])
            let target = AXWindowIdentity(
                bundleIdentifier: "com.example.NotAllowed",
                processID: 101,
                title: "Scene Shelf AX Fixture - Main",
                identifier: "main"
            )
            let report = await adapter.perform(request(for: target))
            expect(report.failureReason == .bundleNotAllowed)
            expect(report.writesPerformed == 0)
            let writes = await adapter.currentWriteCount()
            expect(writes == 0)
        }

        await run("missing candidate performs zero writes") {
            let adapter = FakeAXAdapter(permission: .granted, windows: [])
            let report = await adapter.perform(request(for: fixtureIdentity()))
            expect(report.failureReason == .windowMissing)
            expect(report.writesPerformed == 0)
            let writes = await adapter.currentWriteCount()
            expect(writes == 0)
        }

        await run("discovery preserves permission, unavailable, and ambiguous reasons") {
            for reason in [
                FailureReason.permissionDenied,
                FailureReason.applicationUnavailable,
                FailureReason.ambiguousMatch
            ] {
                let result = AXWindowDiscoveryResult.failure(reason)
                expect(result.windows.isEmpty)
                expect(result.failureReason == reason)
                expect(result.japaneseLabel == reason.japaneseLabel)
            }
        }

        await run("save preparation reports discovery failure instead of missing window") {
            let target = fixtureIdentity()
            for reason in [
                FailureReason.permissionDenied,
                FailureReason.applicationUnavailable,
                FailureReason.ambiguousMatch
            ] {
                let adapter = FakeAXAdapter(
                    permission: .granted,
                    windows: [],
                    discoveryResult: .failure(reason)
                )
                do {
                    _ = try await AXSceneCapturePreparation.prepare(
                        adapter: adapter,
                        selectedIDs: [target]
                    )
                    fail("discovery failure must reject save preparation")
                } catch let error as AXSceneCaptureError {
                    expect(error == .discoveryFailed(reason))
                    expect(error.japaneseLabel.contains(reason.japaneseLabel))
                } catch {
                    fail("unexpected discovery failure: \(error)")
                }
            }
        }

        await run("ambiguous candidates perform zero writes") {
            let candidate = fixtureWindow()
            let duplicate = fixtureWindow()
            let adapter = FakeAXAdapter(permission: .granted, windows: [candidate, duplicate])
            let report = await adapter.perform(request(for: fixtureIdentity()))
            expect(report.failureReason == .ambiguousMatch)
            expect(report.writesPerformed == 0)
            let writes = await adapter.currentWriteCount()
            expect(writes == 0)
        }

        await run("PID reuse performs zero writes") {
            let target = fixtureIdentity(processID: 101)
            let candidate = fixtureWindow(processID: 202)
            let adapter = FakeAXAdapter(permission: .granted, windows: [candidate])
            let report = await adapter.perform(request(for: target))
            expect(report.failureReason == .pidReused)
            expect(report.writesPerformed == 0)
            let writes = await adapter.currentWriteCount()
            expect(writes == 0)
        }

        await run("window hint change performs zero writes") {
            let target = fixtureIdentity(processID: 101)
            let candidate = fixtureWindow(
                processID: 101,
                title: "Scene Shelf AX Fixture - Renamed"
            )
            let adapter = FakeAXAdapter(permission: .granted, windows: [candidate])
            let report = await adapter.perform(request(for: target))
            expect(report.failureReason == .windowChanged)
            expect(report.writesPerformed == 0)
            let writes = await adapter.currentWriteCount()
            expect(writes == 0)
        }

        await run("unique fixture plan applies exact requested operations") {
            let adapter = FakeAXAdapter(permission: .granted, windows: [fixtureWindow()])
            let operations: [AXOperation] = [.move, .resize, .minimize]
            let targetFrame = AXFrame(x: 120, y: 140, width: 800, height: 600)
            let report = await adapter.perform(
                AXOperationRequest(
                    target: fixtureIdentity(),
                    frame: targetFrame,
                    operations: operations
                )
            )
            expect(report.succeeded)
            expect(report.appliedOperations == operations)
            expect(report.writesPerformed == operations.count)
            let writes = await adapter.currentWriteCount()
            let requestCount = await adapter.requestCount()
            expect(writes == operations.count)
            expect(requestCount == 1)
            let readBack = await adapter.fixtureWindows().first
            expect(readBack?.frame == targetFrame)
            expect(readBack?.isMinimized == true)
        }

        await run("move and resize with unavailable frame perform zero writes") {
            for operation in [AXOperation.move, .resize] {
                let adapter = FakeAXAdapter(
                    permission: .granted,
                    windows: [fixtureWindow(frame: nil)]
                )
                let report = await adapter.perform(
                    AXOperationRequest(
                        target: fixtureIdentity(),
                        frame: AXFrame(x: 120, y: 140, width: 800, height: 600),
                        operations: [operation]
                    )
                )
                expect(report.failureReason == .operationFailed)
                expect(report.appliedOperations.isEmpty)
                expect(report.writesPerformed == 0)
                let writes = await adapter.currentWriteCount()
                expect(writes == 0)
                let readBack = await adapter.fixtureWindows().first
                expect(readBack?.frame == nil)
            }
        }

        await run("unminimize is a safe display operation") {
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [fixtureWindow(minimized: true)]
            )
            let operation: [AXOperation] = [.unminimize]
            let report = await adapter.perform(
                AXOperationRequest(
                    target: fixtureIdentity(),
                    operations: operation
                )
            )
            expect(report.succeeded)
            expect(report.appliedOperations == operation)
            expect(report.writesPerformed == 1)
            let writes = await adapter.currentWriteCount()
            expect(writes == 1)
            let readBack = await adapter.fixtureWindows().first
            expect(readBack?.isMinimized == false)
        }

        await run("write-before-resolve rejects a changed candidate") {
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [fixtureWindow()],
                candidateSequence: [
                    [fixtureWindow()],
                    [fixtureWindow(title: "Scene Shelf AX Fixture - Changed")]
                ]
            )
            let report = await adapter.perform(
                AXOperationRequest(
                    target: fixtureIdentity(),
                    frame: AXFrame(x: 120, y: 140, width: 800, height: 600),
                    operations: [.move, .resize]
                )
            )
            expect(report.failureReason == .windowChanged)
            expect(report.appliedOperations == [.move])
            expect(report.writesPerformed == 1)
            let writes = await adapter.currentWriteCount()
            expect(writes == 1)
        }

        await run("save preparation re-reads the live frame after detection") {
            let detectedFrame = AXFrame(x: 20, y: 40, width: 500, height: 300)
            let liveFrame = AXFrame(x: 900, y: 120, width: 900, height: 700)
            let detected = fixtureWindow(frame: detectedFrame)
            let moved = fixtureWindow(frame: liveFrame)
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [moved],
                candidateSequence: [[detected], [moved]]
            )
            let detectedWindows = await adapter.fixtureWindows()
            let selectedIDs = Set(detectedWindows.map(\.identity))
            do {
                let preparation = try await AXSceneCapturePreparation.prepare(
                    adapter: adapter,
                    selectedIDs: selectedIDs
                )
                expect(preparation.candidates.first?.frame == liveFrame)
                expect(preparation.candidates.first?.frame != detectedFrame)
            } catch {
                fail("live snapshot preparation unexpectedly failed: \(error)")
            }
        }

        await run("save preparation rejects a selected window that disappeared") {
            let target = fixtureIdentity()
            let adapter = FakeAXAdapter(permission: .granted, windows: [])
            do {
                _ = try await AXSceneCapturePreparation.prepare(
                    adapter: adapter,
                    selectedIDs: [target]
                )
                fail("missing selected window must reject save preparation")
            } catch let error as AXSceneCaptureError {
                expect(error == .windowMissing(target))
            } catch {
                fail("unexpected missing-window error: \(error)")
            }
        }

        await run("save preparation rejects a selected window without a frame") {
            let target = fixtureIdentity()
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [fixtureWindow(frame: nil)]
            )
            do {
                _ = try await AXSceneCapturePreparation.prepare(
                    adapter: adapter,
                    selectedIDs: [target]
                )
                fail("nil frame must reject save preparation")
            } catch let error as AXSceneCaptureError {
                expect(error == .frameUnavailable(target))
            } catch {
                fail("unexpected nil-frame error: \(error)")
            }
        }

        await run("save preparation preserves selection exclusion") {
            let main = fixtureWindow(identifier: "main")
            let secondary = fixtureWindow(identifier: "secondary")
            let adapter = FakeAXAdapter(
                permission: .granted,
                windows: [main, secondary]
            )
            do {
                let preparation = try await AXSceneCapturePreparation.prepare(
                    adapter: adapter,
                    selectedIDs: [main.identity]
                )
                expect(preparation.candidates.map(\.identity) == [main.identity, secondary.identity])
                expect(preparation.selectedIDs == [main.identity])
            } catch {
                fail("selection exclusion preparation unexpectedly failed: \(error)")
            }
        }

        await run("selected candidates isolate the store input from unselected duplicates") {
            let selected = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Draft",
                identifier: "draft"
            )
            let duplicateUnselected = applicationWindow(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Notes",
                identifier: "notes"
            )
            do {
                let preparation = try AXSceneCapturePreparation.prepare(
                    candidates: [selected, duplicateUnselected, duplicateUnselected],
                    selectedIDs: [selected.identity]
                )
                expect(preparation.selectedCandidates == [selected])
            } catch {
                fail("selected candidate projection unexpectedly failed: \(error)")
            }
        }

        await run("public AX contract contains Sendable values only") {
            let snapshot = fixtureWindow()
            let value: any Sendable = snapshot
            expect(value is AXWindowSnapshot)
            expect(String(describing: type(of: value)).contains("AXUIElement") == false)
            expect(String(describing: type(of: value)).contains("NSRunningApplication") == false)
        }

        if failures == 0 {
            print("SceneShelfAXTestRunner: \(executedTests) tests passed")
        } else {
            print("SceneShelfAXTestRunner: \(failures) failures across \(executedTests) tests")
            Foundation.exit(1)
        }
    }

    private static func probeSystemBoundaryIfRequested() async {
        guard CommandLine.arguments.contains("--probe-system") else { return }
        let adapter = AXSystemAdapter()
        let status = await adapter.permissionStatus()
        print("SYSTEM permission: \(status.state.rawValue) / \(status.reason)")
        guard status.state == .granted else {
            print("SYSTEM AX write: BLOCKED (permission denied; no write attempted)")
            return
        }
        let windows = await adapter.fixtureWindows()
        print("SYSTEM fixture windows: \(windows.count)")
        if windows.isEmpty {
            print("SYSTEM AX write: BLOCKED (fixture unavailable; no write attempted)")
        } else {
            print("SYSTEM AX write: NOT RUN (probe mode never writes)")
        }
    }

    private static func run(_ name: String, _ body: () async -> Void) async {
        executedTests += 1
        let before = failures
        await body()
        if failures == before {
            print("PASS: \(name)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool) {
        if !condition() {
            failures += 1
            print("FAIL")
        }
    }

    private static func fail(_ message: String) {
        failures += 1
        print("FAIL: \(message)")
    }

    private static func fixtureIdentity(
        processID: Int32 = 101,
        identifier: String = "main",
        title: String? = nil
    ) -> AXWindowIdentity {
        AXWindowIdentity(
            bundleIdentifier: SceneShelfAXContract.fixtureBundleIdentifier,
            processID: processID,
            title: title ?? (identifier == "secondary" ? "Scene Shelf AX Fixture - Secondary" : "Scene Shelf AX Fixture - Main"),
            identifier: identifier
        )
    }

    private static func fixtureWindow(
        processID: Int32 = 101,
        title: String? = nil,
        identifier: String = "main",
        minimized: Bool = false,
        frame: AXFrame? = AXFrame(x: 180, y: 620, width: 360, height: 220)
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            identity: AXWindowIdentity(
                bundleIdentifier: SceneShelfAXContract.fixtureBundleIdentifier,
                processID: processID,
                title: title ?? (identifier == "secondary" ? "Scene Shelf AX Fixture - Secondary" : "Scene Shelf AX Fixture - Main"),
                identifier: identifier
            ),
            frame: frame,
            isMinimized: minimized
        )
    }

    private static func request(for target: AXWindowIdentity) -> AXOperationRequest {
        AXOperationRequest(
            target: target,
            frame: AXFrame(x: 120, y: 140, width: 800, height: 600),
            operations: [.move]
        )
    }

    private static func request(
        for target: AXWindowIdentity,
        scope: AXAuthorizationScope
    ) -> AXOperationRequest {
        AXOperationRequest(
            target: target,
            frame: AXFrame(x: 120, y: 140, width: 800, height: 600),
            operations: [.move],
            authorizationScope: scope
        )
    }

    private static func applicationWindow(
        bundleIdentifier: String,
        processID: Int32,
        title: String,
        identifier: String?,
        frame: AXFrame? = AXFrame(x: 180, y: 620, width: 360, height: 220),
        minimized: Bool = false
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            identity: AXWindowIdentity(
                bundleIdentifier: bundleIdentifier,
                processID: processID,
                title: title,
                identifier: identifier
            ),
            frame: frame,
            isMinimized: minimized
        )
    }

    private static func applicationProcess(
        appName: String,
        bundleIdentifier: String?,
        processID: Int32,
        hasUserInterface: Bool = true,
        isBackgroundOnly: Bool = false,
        window: AXWindowSnapshot? = nil
    ) -> AXApplicationProcessSnapshot {
        let defaultWindow = AXWindowSnapshot(
            identity: AXWindowIdentity(
                bundleIdentifier: bundleIdentifier ?? "",
                processID: processID,
                title: "\(appName) Window",
                identifier: "window"
            ),
            frame: AXFrame(x: 10, y: 20, width: 640, height: 480),
            isMinimized: false
        )
        return AXApplicationProcessSnapshot(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            processID: processID,
            windows: [window ?? defaultWindow],
            hasUserInterface: hasUserInterface,
            isBackgroundOnly: isBackgroundOnly
        )
    }
}

private actor FakeAXAdapter: AXWindowAdapter {
    private let permission: PermissionState
    private var windows: [AXWindowSnapshot]
    private var candidateSequence: [[AXWindowSnapshot]]
    private let discoveryResult: AXWindowDiscoveryResult?
    private let catalogResult: AXApplicationCatalogResult?
    private(set) var writeCount = 0
    private(set) var observedRequests: [AXOperationRequest] = []
    private(set) var observedWindowDiscoveryTargets: [AXWindowIdentity] = []

    init(
        permission: PermissionState,
        windows: [AXWindowSnapshot],
        candidateSequence: [[AXWindowSnapshot]] = [],
        discoveryResult: AXWindowDiscoveryResult? = nil,
        catalogResult: AXApplicationCatalogResult? = nil
    ) {
        self.permission = permission
        self.windows = windows
        self.candidateSequence = candidateSequence
        self.discoveryResult = discoveryResult
        self.catalogResult = catalogResult
    }

    func permissionStatus() -> PermissionStatus {
        PermissionStatus(
            state: permission,
            reason: permission == .granted ? "granted" : "denied",
            allowsAXInspection: permission == .granted
        )
    }

    func fixtureWindows() -> [AXWindowSnapshot] {
        if candidateSequence.isEmpty {
            return windows
        }
        return candidateSequence.removeFirst()
    }

    func fixtureWindowResult() -> AXWindowDiscoveryResult {
        discoveryResult ?? .success(fixtureWindows())
    }

    func applicationCatalog() async -> AXApplicationCatalogResult {
        catalogResult ?? .success([])
    }

    func windowResult(for target: AXWindowIdentity) async -> AXWindowDiscoveryResult {
        observedWindowDiscoveryTargets.append(target)
        return .success(windows)
    }

    func currentWriteCount() -> Int { writeCount }

    func requestCount() -> Int { observedRequests.count }

    func requests() -> [AXOperationRequest] { observedRequests }

    func windowDiscoveryCount() -> Int { observedWindowDiscoveryTargets.count }

    func perform(_ request: AXOperationRequest) -> AXOperationReport {
        observedRequests.append(request)
        guard permission == .granted else {
            return report(for: request, failure: .permissionDenied)
        }

        if let scope = request.authorizationScope {
            let authorization = AXAuthorizationPolicy.authorize(
                target: request.target,
                scope: scope
            )
            guard authorization == .authorized else {
                return report(
                    for: request,
                    failure: authorization.failureReason ?? .targetNotAuthorized
                )
            }
        }

        var applied: [AXOperation] = []
        for operation in request.operations {
            let candidates: [AXWindowSnapshot]
            if candidateSequence.isEmpty {
                candidates = windows
            } else {
                candidates = candidateSequence.removeFirst()
            }
            let resolution: AXResolution
            if request.authorizationScope == nil {
                resolution = AXSafetyPolicy.resolve(
                    target: request.target,
                    candidates: candidates
                )
            } else {
                resolution = AXApplicationSafetyPolicy.resolve(
                    target: request.target,
                    candidates: candidates
                )
            }
            switch resolution {
            case .unique:
                guard apply(operation, to: request.target, frame: request.frame) else {
                    return report(
                        for: request,
                        applied: applied,
                        writes: applied.count,
                        failure: .operationFailed
                    )
                }
                writeCount += 1
                applied.append(operation)
            case let resolution:
                return report(
                    for: request,
                    applied: applied,
                    writes: applied.count,
                    failure: resolution.failureReason ?? .operationFailed
                )
            }
        }
        return report(for: request, applied: applied, writes: applied.count)
    }

    private func apply(
        _ operation: AXOperation,
        to target: AXWindowIdentity,
        frame: AXFrame?
    ) -> Bool {
        guard let index = windows.firstIndex(where: { $0.identity == target }) else {
            return false
        }
        let current = windows[index]
        switch operation {
        case .unminimize:
            windows[index] = AXWindowSnapshot(
                identity: current.identity,
                frame: current.frame,
                isMinimized: false
            )
            return true
        case .move:
            guard let frame, let currentFrame = current.frame else { return false }
            windows[index] = AXWindowSnapshot(
                identity: current.identity,
                frame: AXFrame(
                    x: frame.x,
                    y: frame.y,
                    width: currentFrame.width,
                    height: currentFrame.height
                ),
                isMinimized: current.isMinimized
            )
            return true
        case .resize:
            guard let frame, let currentFrame = current.frame else { return false }
            windows[index] = AXWindowSnapshot(
                identity: current.identity,
                frame: AXFrame(
                    x: currentFrame.x,
                    y: currentFrame.y,
                    width: frame.width,
                    height: frame.height
                ),
                isMinimized: current.isMinimized
            )
            return true
        case .minimize:
            windows[index] = AXWindowSnapshot(
                identity: current.identity,
                frame: current.frame,
                isMinimized: true
            )
            return true
        }
    }

    private func report(
        for request: AXOperationRequest,
        applied: [AXOperation] = [],
        writes: Int = 0,
        failure: FailureReason? = nil
    ) -> AXOperationReport {
        AXOperationReport(
            target: request.target,
            requestedOperations: request.operations,
            appliedOperations: applied,
            writesPerformed: writes,
            failureReason: failure
        )
    }
}
