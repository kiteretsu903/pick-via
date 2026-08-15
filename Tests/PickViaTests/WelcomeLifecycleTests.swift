import XCTest

@testable import PickVia

@MainActor
final class WelcomeLifecycleTests: XCTestCase {
  func testBrowserStepsRetainTheirExistingContentMapping() {
    XCTAssertEqual(welcomeStep(for: 1), .discovery)
    XCTAssertEqual(welcomeStep(for: 2), .browserReview)
    XCTAssertEqual(welcomeStep(for: 3), .defaultBrowser)
  }

  func testMailStepsMapToReviewAndDefaultContent() {
    XCTAssertEqual(welcomeStep(for: 4), .mailReview)
    XCTAssertEqual(welcomeStep(for: 5), .defaultMail)
  }

  func testCompletedStepMapsToNoWelcomeContent() {
    XCTAssertNil(welcomeStep(for: 6))
  }

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
