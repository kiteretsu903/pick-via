import Foundation
import Testing
@testable import PickViaCore

struct BrowserLauncherTests {
    private let url = URL(string: "https://example.com")!

    @Test func chromiumNormalPlanUsesExactProfileAndURLTokens() throws {
        let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: RecordingWorkspace())

        let plan = try launcher.makePlan(
            url: URL(string: "https://example.com/a?x=1")!,
            application: application(family: .chromium),
            target: target(profile: "Profile 1")
        )

        guard case let .executable(application, arguments) = plan else {
            Issue.record("Expected executable launch plan")
            return
        }
        #expect(application == executableURL)
        #expect(arguments == ["--profile-directory=Profile 1", "https://example.com/a?x=1"])
    }

    @Test func chromiumPrivatePlanUsesExactProfileIncognitoAndURLTokens() throws {
        let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: RecordingWorkspace())

        let plan = try launcher.makePlan(
            url: url,
            application: application(family: .chromium),
            target: target(profile: "Profile 1", mode: .private)
        )

        guard case let .executable(_, arguments) = plan else {
            Issue.record("Expected executable launch plan")
            return
        }
        #expect(arguments == ["--profile-directory=Profile 1", "--incognito", "https://example.com"])
    }

    @Test func firefoxNormalPlanUsesExactProfileNewTabAndURLTokens() throws {
        let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: RecordingWorkspace())

        let plan = try launcher.makePlan(
            url: url,
            application: application(family: .firefox),
            target: target(profile: "work")
        )

        guard case let .executable(_, arguments) = plan else {
            Issue.record("Expected executable launch plan")
            return
        }
        #expect(arguments == ["-P", "work", "-new-tab", "https://example.com"])
    }

    @Test func firefoxPrivatePlanUsesExactProfilePrivateWindowAndURLTokens() throws {
        let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: RecordingWorkspace())

        let plan = try launcher.makePlan(
            url: url,
            application: application(family: .firefox),
            target: target(profile: "work", mode: .private)
        )

        guard case let .executable(_, arguments) = plan else {
            Issue.record("Expected executable launch plan")
            return
        }
        #expect(arguments == ["-P", "work", "-private-window", "https://example.com"])
    }

    @Test func safariNormalPlanUsesWorkspaceOpening() throws {
        let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: RecordingWorkspace())
        let safari = application(family: .safari, executable: nil)

        let plan = try launcher.makePlan(url: url, application: safari, target: target(profile: nil))

        #expect(plan == .workspace(application: safari.applicationURL, url: url))
    }

    @Test(arguments: [
        target(profile: "Personal"),
        target(profile: nil, mode: .private),
    ])
    func safariRejectsProfileAndPrivateTargets(safariTarget: BrowserTarget) {
        let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: RecordingWorkspace())

        #expect(throws: LaunchFailure.self) {
            try launcher.makePlan(
                url: url,
                application: application(family: .safari, executable: nil),
                target: safariTarget
            )
        }
    }

    @Test func mismatchedBrowserIDIsRejected() {
        let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: RecordingWorkspace())

        #expect(throws: LaunchFailure.self) {
            try launcher.makePlan(
                url: url,
                application: application(family: .chromium),
                target: target(browserID: "org.mozilla.firefox", profile: "work")
            )
        }
    }

    @Test func missingExecutableFailsBeforeProcessLaunch() async {
        let process = RecordingProcessRunner()
        let launcher = BrowserLauncher(processRunner: process, workspace: RecordingWorkspace())

        await #expect(throws: LaunchFailure.self) {
            try await launcher.launch(
                url: url,
                application: application(family: .chromium, executable: nil),
                target: target(profile: "Profile 1")
            )
        }
        #expect(process.invocations.isEmpty)
    }

    @Test func shellMetacharactersRemainOneURLArgument() throws {
        let dangerousURL = URL(string: "https://example.com/a?x=%24%28touch%20%2Ftmp%2Fpwned%29%3B%26y=1")!
        let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: RecordingWorkspace())

        let plan = try launcher.makePlan(
            url: dangerousURL,
            application: application(family: .chromium),
            target: target(profile: "Profile 1")
        )

        guard case let .executable(_, arguments) = plan else {
            Issue.record("Expected executable launch plan")
            return
        }
        #expect(arguments.count == 2)
        #expect(arguments.last == dangerousURL.absoluteString)
    }

    @Test func executeDispatchesExecutablePlanToInjectedProcessRunner() async throws {
        let process = RecordingProcessRunner()
        let launcher = BrowserLauncher(processRunner: process, workspace: RecordingWorkspace())
        let plan = LaunchPlan.executable(application: executableURL, arguments: ["-P", "work", url.absoluteString])

        try await launcher.execute(plan)

        #expect(process.invocations == [.init(application: executableURL, arguments: ["-P", "work", url.absoluteString])])
    }

    @Test func executeDispatchesWorkspacePlanToInjectedWorkspace() async throws {
        let workspace = RecordingWorkspace()
        let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: workspace)
        let appURL = applicationURL

        try await launcher.execute(.workspace(application: appURL, url: url))

        #expect(workspace.invocations == [.init(application: appURL, url: url)])
    }

    @Test(arguments: [ExecutionKind.process, .workspace])
    func executionErrorsBecomeSanitizedLaunchFailures(kind: ExecutionKind) async {
        let underlying = NSError(
            domain: "BrowserLauncherTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "failed for https://secret.example/private"]
        )
        let process = RecordingProcessRunner(error: underlying)
        let workspace = RecordingWorkspace(error: underlying)
        let launcher = BrowserLauncher(processRunner: process, workspace: workspace)
        let plan: LaunchPlan = switch kind {
        case .process:
            .executable(application: executableURL, arguments: [url.absoluteString])
        case .workspace:
            .workspace(application: applicationURL, url: url)
        }

        do {
            try await launcher.execute(plan)
            Issue.record("Expected execution failure")
        } catch let failure as LaunchFailure {
            #expect(failure.message == "Could not open the selected browser target.")
            #expect(!failure.message.contains("secret.example"))
            #expect(!failure.message.contains(url.absoluteString))
        } catch {
            Issue.record("Expected LaunchFailure, got \(type(of: error))")
        }
    }
}

private let applicationURL = URL(fileURLWithPath: "/Applications/Browser.app", isDirectory: true)
private let executableURL = applicationURL.appending(path: "Contents/MacOS/Browser")

private func application(family: BrowserFamily, executable: URL? = executableURL) -> BrowserApplication {
    BrowserApplication(
        id: "com.example.browser",
        family: family,
        displayName: "Browser",
        bundleIdentifier: "com.example.browser",
        applicationURL: applicationURL,
        executableURL: executable,
        isAvailable: true
    )
}

private func target(
    browserID: BrowserApplication.ID = "com.example.browser",
    profile: String?,
    mode: BrowserMode = .normal
) -> BrowserTarget {
    BrowserTarget(
        id: "target-\(profile ?? "default")-\(mode.rawValue)",
        browserID: browserID,
        label: "Target",
        profileIdentifier: profile,
        profileDisplayName: profile,
        mode: mode,
        isEnabled: true,
        sortOrder: 0,
        origin: .detected,
        availability: .available
    )
}

enum ExecutionKind: Sendable {
    case process
    case workspace
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let application: URL
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func run(executable application: URL, arguments: [String]) throws {
        invocations.append(.init(application: application, arguments: arguments))
        if let error { throw error }
    }
}

private final class RecordingWorkspace: WorkspaceOpening, @unchecked Sendable {
    struct Invocation: Equatable {
        let application: URL
        let url: URL
    }

    private(set) var invocations: [Invocation] = []
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func open(_ url: URL, withApplicationAt application: URL) async throws {
        invocations.append(.init(application: application, url: url))
        if let error { throw error }
    }
}
