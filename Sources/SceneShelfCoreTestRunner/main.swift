import Foundation
import SceneShelfCore

@main
@MainActor
struct SceneShelfCoreTestRunner {
    private static var failures = 0

    static func main() async {
        await run("fake scenes keep the approved display order") {
            let coordinator = SceneCoordinator(scenes: FakeSceneFactory.defaultScenes)
            let snapshot = await coordinator.snapshot()
            expect(snapshot.cards.map(\.name) == ["開発", "会議"])
        }

        await run("stashed card click completes as displayed") {
            let coordinator = SceneCoordinator(
                scenes: [SceneDefinition(id: "development", name: "開発")]
            )
            let outcome = await coordinator.click(sceneID: "development")
            let snapshot = await coordinator.snapshot()
            expect(outcome == .completed(sceneID: "development", state: .displayed))
            expect(snapshot.cards.first?.state == .displayed)
        }

        await run("displayed card click completes as stashed") {
            let coordinator = SceneCoordinator(
                scenes: [SceneDefinition(id: "development", name: "開発")],
                initialState: .displayed
            )
            let outcome = await coordinator.click(sceneID: "development")
            let snapshot = await coordinator.snapshot()
            expect(outcome == .completed(sceneID: "development", state: .stashed))
            expect(snapshot.cards.first?.state == .stashed)
        }

        await run("busy same card is rejected without a second operation") {
            let gate = OperationGate()
            let coordinator = SceneCoordinator(
                scenes: [SceneDefinition(id: "development", name: "開発")],
                operation: { _, _ in await gate.blockUntilReleased() }
            )
            let firstClick = Task { await coordinator.click(sceneID: "development") }
            await gate.waitForStart()
            let secondOutcome = await coordinator.click(sceneID: "development")
            let preparingSnapshot = await coordinator.snapshot()
            expect(secondOutcome == .busyRejected(sceneID: "development"))
            expect(preparingSnapshot.cards.first?.state == .preparing)
            await gate.release()
            let firstOutcome = await firstClick.value
            let startedCount = await gate.startedCount
            expect(firstOutcome == .completed(sceneID: "development", state: .displayed))
            expect(startedCount == 1)
        }

        await run("busy different card is rejected and not queued") {
            let gate = OperationGate()
            let coordinator = SceneCoordinator(
                scenes: FakeSceneFactory.defaultScenes,
                operation: { _, _ in await gate.blockUntilReleased() }
            )
            let firstClick = Task { await coordinator.click(sceneID: "development") }
            await gate.waitForStart()
            let rejectedOutcome = await coordinator.click(sceneID: "meeting")
            let preparingSnapshot = await coordinator.snapshot()
            expect(rejectedOutcome == .busyRejected(sceneID: "meeting"))
            expect(preparingSnapshot.cards.map(\.state) == [.preparing, .stashed])
            await gate.release()
            let firstOutcome = await firstClick.value
            expect(firstOutcome == .completed(sceneID: "development", state: .displayed))
            let completedSnapshot = await coordinator.snapshot()
            expect(completedSnapshot.cards.map(\.state) == [.displayed, .stashed])
            let startedCount = await gate.startedCount
            expect(startedCount == 1)
        }

        await run("empty scenes return a safe empty shelf result") {
            let coordinator = SceneCoordinator(scenes: [])
            let snapshot = await coordinator.snapshot()
            let outcome = await coordinator.click(sceneID: "missing")
            expect(snapshot.cards.isEmpty)
            expect(outcome == .emptyShelf)
        }

        if failures == 0 {
            print("SceneShelfCoreTestRunner: 6 tests passed")
        } else {
            print("SceneShelfCoreTestRunner: \(failures) failures")
            Foundation.exit(1)
        }
    }

    private static func run(_ name: String, _ body: () async -> Void) async {
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
}

private actor OperationGate {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startedCount = 0

    func waitForStart() async {
        if startedCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func blockUntilReleased() async {
        startedCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
