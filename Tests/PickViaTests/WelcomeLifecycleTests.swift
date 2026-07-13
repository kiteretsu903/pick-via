import XCTest

@testable import PickVia

@MainActor
final class WelcomeLifecycleTests: XCTestCase {
  func testIncompleteOnboardingKeepsWelcomeVisible() {
    var dismissCallCount = 0
    let lifecycle = WelcomeLifecycle(dismiss: { dismissCallCount += 1 })

    lifecycle.synchronize(isOnboardingComplete: false)

    XCTAssertTrue(lifecycle.shouldShowContent(isOnboardingComplete: false))
    XCTAssertEqual(dismissCallCount, 0)
  }

  func testCompletedOnboardingHidesAndDismissesWelcome() {
    var dismissCallCount = 0
    let lifecycle = WelcomeLifecycle(dismiss: { dismissCallCount += 1 })

    lifecycle.synchronize(isOnboardingComplete: true)

    XCTAssertFalse(lifecycle.shouldShowContent(isOnboardingComplete: true))
    XCTAssertEqual(dismissCallCount, 1)
  }
}
