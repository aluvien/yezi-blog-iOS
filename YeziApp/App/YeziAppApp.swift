import SwiftUI

@main
struct YeziAppApp: App {
    @UIApplicationDelegateAdaptor(YeziAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            RootContentView()
        }
    }
}
