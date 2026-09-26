import Foundation
import SceneShelfCore

@main
@MainActor
struct SceneShelfSwitchingTestRunner {
    private static var failures = 0

    static func main() async {
        await run("displayed A hides before stashed B displays") {
            let main = fixtureWindow(id: "main", processID: 101)
            let secondary = fixtureWindow(id: "secondary", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(
                    name: "A",
                    candidates: [main, secondary],
                    selectedIDs: [main.identity]
                )
                let sceneB = try await store.save(
                    name: "B",
                    candidates: [main, secondary],
                    selectedIDs: [secondary.identity]
                )
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let recorder = PlanRecorder()
                let outcome = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    await recorder.record(plan)
                    return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                expect(outcome == .displayed(sceneID: sceneB.id))
                expect(await store.state(sceneID: sceneA.id) == .stashed)
                expect(await store.state(sceneID: sceneB.id) == .displayed)
                expect(await store.currentSceneID() == sceneB.id)
                expect(await recorder.actions() == [
                    .init(sceneID: sceneA.id, action: .hide),
                    .init(sceneID: sceneB.id, action: .display)
                ])
            } catch {
                fail("successful switch setup unexpectedly failed: \(error)")
            }
        }

        await run("partial A hide aborts switch and leaves B untouched") {
            let main = fixtureWindow(id: "main", processID: 101)
            let secondary = fixtureWindow(id: "secondary", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(
                    name: "A",
                    candidates: [main, secondary],
                    selectedIDs: [main.identity, secondary.identity]
                )
                let sceneB = try await store.save(
                    name: "B",
                    candidates: [main, secondary],
                    selectedIDs: [main.identity]
                )
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let recorder = PlanRecorder()
                let outcome = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    await recorder.record(plan)
                    guard plan.action == .hide, plan.instructions.count == 2 else {
                        return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                    }
                    let executed = [
                        SceneTargetRestoreOutcome.succeeded(
                            target: plan.instructions[0].target,
                            appliedOperations: plan.instructions[0].operations
                        ),
                        SceneTargetRestoreOutcome.failed(
                            target: plan.instructions[1].target,
                            reason: .windowMissing
                        )
                    ]
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: executed)
                }
                expect(outcome == .failed(sceneID: sceneA.id))
                expect(await store.state(sceneID: sceneA.id) == .failed)
                expect(await store.report(sceneID: sceneA.id)?.failureReasons == [.windowMissing])
                expect(await store.currentSceneID() == sceneA.id)
                expect(await store.state(sceneID: sceneB.id) == .stashed)
                expect(await recorder.actions() == [
                    .init(sceneID: sceneA.id, action: .hide)
                ])
            } catch {
                fail("partial A hide setup unexpectedly failed: \(error)")
            }
        }

        await run("failed A hide aborts switch and preserves the active scene identity") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(
                    name: "A",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                let sceneB = try await store.save(
                    name: "B",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let recorder = PlanRecorder()
                let outcome = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    await recorder.record(plan)
                    let failed = plan.instructions.map {
                        SceneTargetRestoreOutcome.failed(
                            target: $0.target,
                            reason: .operationFailed
                        )
                    }
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: failed)
                }
                expect(outcome == .failed(sceneID: sceneA.id))
                expect(await store.state(sceneID: sceneA.id) == .failed)
                expect(await store.report(sceneID: sceneA.id)?.failureReasons == [.operationFailed])
                expect(await store.currentSceneID() == sceneA.id)
                expect(await store.state(sceneID: sceneB.id) == .stashed)
                expect(await recorder.actions() == [
                    .init(sceneID: sceneA.id, action: .hide)
                ])
            } catch {
                fail("failed A hide setup unexpectedly failed: \(error)")
            }
        }

        await run("same-card hide failure keeps current A and allows a safe retry") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(
                    name: "A",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                let sceneB = try await store.save(
                    name: "B",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let failedHide = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    let failures = plan.instructions.map {
                        SceneTargetRestoreOutcome.failed(
                            target: $0.target,
                            reason: .operationFailed
                        )
                    }
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: failures)
                }
                expect(failedHide == .failed(sceneID: sceneA.id))
                expect(await store.state(sceneID: sceneA.id) == .failed)
                expect(await store.currentSceneID() == sceneA.id)

                var deleteRejected = false
                do {
                    try await store.delete(sceneID: sceneA.id, confirmed: true)
                } catch let error as SceneManagementError {
                    deleteRejected = error == .sceneActive(sceneA.id)
                }
                expect(deleteRejected)

                let switched = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                expect(switched == .displayed(sceneID: sceneB.id))
                expect(await store.state(sceneID: sceneA.id) == .stashed)
                expect(await store.currentSceneID() == sceneB.id)
            } catch {
                fail("same-card hide retry setup unexpectedly failed: \(error)")
            }
        }

        await run("A hide retry and B display retry recover in sequence") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(name: "A", candidates: [main], selectedIDs: [main.identity])
                let sceneB = try await store.save(name: "B", candidates: [main], selectedIDs: [main.identity])
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }

                let failedAHide = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    let failures = plan.instructions.map {
                        SceneTargetRestoreOutcome.failed(
                            target: $0.target,
                            reason: .operationFailed
                        )
                    }
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: failures)
                }
                expect(failedAHide == .failed(sceneID: sceneA.id))
                expect(await store.currentSceneID() == sceneA.id)

                let failedBDisplay = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    if plan.action == .hide {
                        return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                    }
                    let failures = plan.instructions.map {
                        SceneTargetRestoreOutcome.failed(
                            target: $0.target,
                            reason: .operationFailed
                        )
                    }
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: failures)
                }
                expect(failedBDisplay == .failed(sceneID: sceneB.id))
                expect(await store.state(sceneID: sceneA.id) == .stashed)
                expect(await store.state(sceneID: sceneB.id) == .failed)
                expect(await store.currentSceneID() == nil)

                let recoveredB = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                expect(recoveredB == .displayed(sceneID: sceneB.id))
                expect(await store.currentSceneID() == sceneB.id)
            } catch {
                fail("A/B retry sequence setup unexpectedly failed: \(error)")
            }
        }

        await run("partial B display is reported after A is stashed") {
            let main = fixtureWindow(id: "main", processID: 101)
            let secondary = fixtureWindow(id: "secondary", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(
                    name: "A",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                let sceneB = try await store.save(
                    name: "B",
                    candidates: [main, secondary],
                    selectedIDs: [main.identity, secondary.identity]
                )
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let recorder = PlanRecorder()
                let outcome = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    await recorder.record(plan)
                    if plan.action == .hide {
                        return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                    }
                    let executed = [
                        SceneTargetRestoreOutcome.succeeded(
                            target: plan.instructions[0].target,
                            appliedOperations: plan.instructions[0].operations
                        ),
                        SceneTargetRestoreOutcome.failed(
                            target: plan.instructions[1].target,
                            reason: .windowMissing
                        )
                    ]
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: executed)
                }
                expect(outcome == .partiallyRestored(sceneID: sceneB.id))
                expect(await store.state(sceneID: sceneA.id) == .stashed)
                expect(await store.state(sceneID: sceneB.id) == .partiallyRestored)
                expect(await store.report(sceneID: sceneB.id)?.failureReasons == [.windowMissing])
                expect(await store.currentSceneID() == sceneB.id)
                expect(await recorder.actions() == [
                    .init(sceneID: sceneA.id, action: .hide),
                    .init(sceneID: sceneB.id, action: .display)
                ])
            } catch {
                fail("partial B display setup unexpectedly failed: \(error)")
            }
        }

        await run("failed B display keeps A stashed and follows the existing B report") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(
                    name: "A",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                let sceneB = try await store.save(
                    name: "B",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let recorder = PlanRecorder()
                let outcome = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    await recorder.record(plan)
                    if plan.action == .hide {
                        return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                    }
                    let failed = plan.instructions.map {
                        SceneTargetRestoreOutcome.failed(
                            target: $0.target,
                            reason: .operationFailed
                        )
                    }
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: failed)
                }
                expect(outcome == .failed(sceneID: sceneB.id))
                expect(await store.state(sceneID: sceneA.id) == .stashed)
                expect(await store.state(sceneID: sceneB.id) == .failed)
                expect(await store.report(sceneID: sceneB.id)?.failureReasons == [.operationFailed])
                expect(await store.currentSceneID() == nil)
                expect(await recorder.actions() == [
                    .init(sceneID: sceneA.id, action: .hide),
                    .init(sceneID: sceneB.id, action: .display)
                ])
            } catch {
                fail("failed B display setup unexpectedly failed: \(error)")
            }
        }

        await run("failed B display can be retried from its failed state") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(name: "A", candidates: [main], selectedIDs: [main.identity])
                let sceneB = try await store.save(name: "B", candidates: [main], selectedIDs: [main.identity])
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let failedSwitch = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    if plan.action == .hide {
                        return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                    }
                    let failures = plan.instructions.map {
                        SceneTargetRestoreOutcome.failed(
                            target: $0.target,
                            reason: .operationFailed
                        )
                    }
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: failures)
                }
                expect(failedSwitch == .failed(sceneID: sceneB.id))
                expect(await store.state(sceneID: sceneA.id) == .stashed)
                expect(await store.state(sceneID: sceneB.id) == .failed)
                expect(await store.currentSceneID() == nil)

                let retried = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                expect(retried == .displayed(sceneID: sceneB.id))
                expect(await store.state(sceneID: sceneB.id) == .displayed)
                expect(await store.currentSceneID() == sceneB.id)
            } catch {
                fail("failed B display retry setup unexpectedly failed: \(error)")
            }
        }

        await run("all switch steps share one busy interval") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(name: "A", candidates: [main], selectedIDs: [main.identity])
                let sceneB = try await store.save(name: "B", candidates: [main], selectedIDs: [main.identity])
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let gate = OperationGate()
                let firstSwitch = Task {
                    await store.clickDetailed(sceneID: sceneB.id) { plan in
                        await gate.started()
                        await gate.waitForRelease()
                        return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                    }
                }
                await gate.waitUntilStarted()
                let rejected = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                expect(rejected == .busyRejected(sceneID: sceneA.id))
                await gate.release()
                expect(await firstSwitch.value == .displayed(sceneID: sceneB.id))
            } catch {
                fail("busy switch setup unexpectedly failed: \(error)")
            }
        }

        await run("same-card display and hide keep the existing roundtrip contract") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let scene = try await store.save(name: "same", candidates: [main], selectedIDs: [main.identity])
                let displayed = await store.clickDetailed(sceneID: scene.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let hidden = await store.clickDetailed(sceneID: scene.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                expect(displayed == .displayed(sceneID: scene.id))
                expect(hidden == .stashed(sceneID: scene.id))
                expect(await store.currentSceneID() == nil)
            } catch {
                fail("same-card setup unexpectedly failed: \(error)")
            }
        }

        await run("legacy bool switching keeps A hidden when B display fails") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(name: "A", candidates: [main], selectedIDs: [main.identity])
                let sceneB = try await store.save(name: "B", candidates: [main], selectedIDs: [main.identity])
                let displayed = await store.click(sceneID: sceneA.id) { _ in true }
                let outcome = await store.click(sceneID: sceneB.id) { plan in
                    plan.action == .hide
                }
                expect(displayed == .displayed(sceneID: sceneA.id))
                expect(outcome == .operationFailed(sceneID: sceneB.id))
                expect(await store.state(sceneID: sceneA.id) == .stashed)
                expect(await store.state(sceneID: sceneB.id) == .failed)
                expect(await store.currentSceneID() == nil)
            } catch {
                fail("legacy bool switch setup unexpectedly failed: \(error)")
            }
        }

        await run("failed A hide rejects confirmed delete and preserves the active switch boundary") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(name: "A", candidates: [main], selectedIDs: [main.identity])
                let sceneB = try await store.save(name: "B", candidates: [main], selectedIDs: [main.identity])
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                _ = await store.clickDetailed(sceneID: sceneB.id) { plan in
                    let failed = plan.instructions.map {
                        SceneTargetRestoreOutcome.failed(
                            target: $0.target,
                            reason: .operationFailed
                        )
                    }
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: failed)
                }

                var rejected = false
                do {
                    try await store.delete(sceneID: sceneA.id, confirmed: true)
                } catch let error as SceneManagementError {
                    rejected = error == .sceneActive(sceneA.id)
                }

                expect(rejected)
                expect(await store.state(sceneID: sceneA.id) == .failed)
                expect(await store.report(sceneID: sceneA.id)?.failureReasons == [.operationFailed])
                expect(await store.currentSceneID() == sceneA.id)
                expect(await store.state(sceneID: sceneB.id) == .stashed)
                expect((await store.scenes()).map(\.id) == [sceneA.id, sceneB.id])
            } catch {
                fail("failed-hide delete boundary setup unexpectedly failed: \(error)")
            }
        }

        await run("missing target is rejected without touching the active scene") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let sceneA = try await store.save(name: "A", candidates: [main], selectedIDs: [main.identity])
                _ = await store.clickDetailed(sceneID: sceneA.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let outcome = await store.clickDetailed(sceneID: "missing") { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                expect(outcome == .sceneNotFound(sceneID: "missing"))
                expect(await store.state(sceneID: sceneA.id) == .displayed)
                expect(await store.currentSceneID() == sceneA.id)
            } catch {
                fail("missing target setup unexpectedly failed: \(error)")
            }
        }

        if failures == 0 {
            print("SceneShelfSwitchingTestRunner: 13 tests passed")
        } else {
            print("SceneShelfSwitchingTestRunner: \(failures) failures")
            Foundation.exit(1)
        }
    }

    private static func fixtureWindow(id: String, processID: Int32) -> SceneWindowSnapshot {
        SceneWindowSnapshot(
            identity: SceneWindowIdentity(
                bundleIdentifier: SceneMatcher.fixtureBundleIdentifier,
                processID: processID,
                title: "Scene Shelf AX Fixture - \(id.capitalized)",
                identifier: id
            ),
            frame: SceneFrame(x: 120, y: 140, width: 800, height: 600),
            isMinimized: false
        )
    }

    private static func run(_ name: String, _ body: () async -> Void) async {
        let before = failures
        await body()
        if failures == before {
            print("PASS: \(name)")
        } else {
            print("FAIL: \(name)")
        }
    }

    private static func expect(_ condition: Bool) {
        if !condition {
            failures += 1
            print("FAIL")
        }
    }

    private static func fail(_ message: String) {
        failures += 1
        print("FAIL: \(message)")
    }
}

private struct RecordedAction: Equatable, Sendable {
    let sceneID: SceneID
    let action: SceneRestoreAction
}

private actor PlanRecorder {
    private var recorded: [RecordedAction] = []

    func record(_ plan: SceneRestorePlan) {
        recorded.append(RecordedAction(sceneID: plan.sceneID, action: plan.action))
    }

    func actions() -> [RecordedAction] {
        recorded
    }
}

private actor OperationGate {
    private var hasStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func started() {
        hasStarted = true
        let pending = startWaiters
        startWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
