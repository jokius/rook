import os
import XCTest
@testable import rook

/// `ghostty_surface_new` returns NULL for as long as the display is asleep, so a session a scheduled job
/// creates in that window realizes no surface and its `--command` never runs. Nothing else re-attempts —
/// SwiftUI runs no layout for an off-display window — so this bridge is the only thing that revives the
/// pane. Measured: creation starts succeeding at display wake, with the screen still locked.
@MainActor
final class SystemWakeObserverTests: XCTestCase {
    /// Held by the case, not by each test, so `tearDown` drops it DETERMINISTICALLY: the registration lives
    /// in `NSWorkspace.notificationCenter` and is only withdrawn by `isolated deinit`, so an observer left
    /// alive by a finished test keeps reposting into the next one.
    private var observer: SystemWakeObserver?

    override func tearDown() {
        observer = nil
        super.tearDown()
    }

    func testDisplayWakeIsRepostedOnTheAppNotificationCenter() {
        let observer = SystemWakeObserver()
        self.observer = observer
        observer.start()

        let reposted = expectation(forNotification: .rookScreensDidWake, object: nil, notificationCenter: .default)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        wait(for: [reposted], timeout: 2)
    }

    /// Measures the DELTA, not the absolute count: these tests run in the app host, whose scene `.task`
    /// starts an observer of its own, so a wake already draws a repost before this test registers anything.
    /// Asserting "exactly one repost" would be asserting that the host is not running. Three `start()`s must
    /// add exactly ONE repost over the baseline — drop the idempotence guard and this reads three.
    func testStartIsIdempotentSoOneWakeStaysOneRepost() {
        let baseline = repostsForOneWake()

        let observer = SystemWakeObserver()
        self.observer = observer
        observer.start()
        observer.start()
        observer.start()

        let withObserver = repostsForOneWake()

        XCTAssertEqual(withObserver - baseline, 1,
                       "the scene .task starts this per window, so repeated starts must not fan out")
    }

    /// Posts one workspace wake and returns how many `.rookScreensDidWake` reposts it produced.
    ///
    /// Waiting on one main-queue turn is not enough: the observer reposts from its own
    /// `DispatchQueue.main.async` while the workspace notification arrives via `OperationQueue.main`, and
    /// nothing orders those two. So wait for the FIRST repost, then drain two more turns, which is what lets
    /// a second and third repost be counted rather than missed.
    private func repostsForOneWake() -> Int {
        // A lock rather than a captured `var`: NotificationCenter's block is @Sendable even on a main queue,
        // so incrementing a local from it warns under concurrency checking. Every increment does land on the
        // main queue, so the lock only quiets the compiler — it is the project's idiom for exactly that.
        let reposts = OSAllocatedUnfairLock(initialState: 0)
        let token = NotificationCenter.default.addObserver(forName: .rookScreensDidWake, object: nil,
                                                          queue: .main) { _ in reposts.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        let arrived = expectation(forNotification: .rookScreensDidWake, object: nil, notificationCenter: .default)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        wait(for: [arrived], timeout: 2)

        let drained = expectation(description: "any further reposts delivered")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)

        return reposts.withLock { $0 }
    }
}
