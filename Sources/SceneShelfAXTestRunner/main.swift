import Foundation
import SceneShelfAccessibility

@main
@MainActor
struct SceneShelfAXTestRunner {
    private static var failures = 0
    private static var executedTests = 0

    static func main() async {
        await probeSystemBoundaryIfRequested()
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
}

private actor FakeAXAdapter: AXWindowAdapter {
    private let permission: PermissionState
    private var windows: [AXWindowSnapshot]
    private var candidateSequence: [[AXWindowSnapshot]]
    private let discoveryResult: AXWindowDiscoveryResult?
    private(set) var writeCount = 0
    private(set) var observedRequests: [AXOperationRequest] = []

    init(
        permission: PermissionState,
        windows: [AXWindowSnapshot],
        candidateSequence: [[AXWindowSnapshot]] = [],
        discoveryResult: AXWindowDiscoveryResult? = nil
    ) {
        self.permission = permission
        self.windows = windows
        self.candidateSequence = candidateSequence
        self.discoveryResult = discoveryResult
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

    func currentWriteCount() -> Int { writeCount }

    func requestCount() -> Int { observedRequests.count }

    func perform(_ request: AXOperationRequest) -> AXOperationReport {
        observedRequests.append(request)
        guard permission == .granted else {
            return report(for: request, failure: .permissionDenied)
        }

        var applied: [AXOperation] = []
        for operation in request.operations {
            let candidates: [AXWindowSnapshot]
            if candidateSequence.isEmpty {
                candidates = windows
            } else {
                candidates = candidateSequence.removeFirst()
            }
            switch AXSafetyPolicy.resolve(target: request.target, candidates: candidates) {
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
