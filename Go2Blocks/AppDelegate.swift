import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // A robot is being driven: the iPad must not dim and lock while the editor is open.
        // (Safari cannot promise this over plain http; an app can.)
        application.isIdleTimerDisabled = true
        UpdateManager.shared.beginLaunch()      // an update that never started last time is dropped
        // The sound blocks must be heard even with the iPad's silent switch on, and from the
        // speaker (not the earpiece); the same session records for the sounds screen.
        // (Off the main thread: activating a session can block the screen for a moment.)
        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try? session.setActive(true)
        }
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
