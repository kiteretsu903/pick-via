import Foundation

public struct RouteLauncher: RouteLaunching, Sendable {
  let browserLauncher: BrowserLauncher
  let mailLauncher: MailLauncher

  public init(
    browserLauncher: BrowserLauncher = BrowserLauncher(),
    mailLauncher: MailLauncher = MailLauncher()
  ) {
    self.browserLauncher = browserLauncher
    self.mailLauncher = mailLauncher
  }

  public func launch(
    url: URL,
    application: RoutedApplication,
    target: RouteTarget
  ) async throws {
    switch target.capability {
    case .browser:
      try await browserLauncher.launch(url: url, application: application, target: target)
    case .mail:
      try await mailLauncher.launch(url: url, application: application, target: target)
    }
  }
}
