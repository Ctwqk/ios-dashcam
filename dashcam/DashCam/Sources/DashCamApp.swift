import SwiftUI

@main
struct DashCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            DashcamView()
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }
}
