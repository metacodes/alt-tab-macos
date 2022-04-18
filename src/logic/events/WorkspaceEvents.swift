import Cocoa

class WorkspaceEvents {
    private static var appsObserver: NSKeyValueObservation!
    private static var previousValueOfRunningApps: Set<NSRunningApplication>!

    static func observeRunningApplications() {
        previousValueOfRunningApps = Set(NSWorkspace.shared.runningApplications)
        appsObserver = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new], changeHandler: observerCallback)
    }

    static func observerCallback<A>(_ application: NSWorkspace, _ change: NSKeyValueObservedChange<A>) {
    }

    static func registerFrontAppChangeNote() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveFrontAppChangeNote(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveFrontAppLaunchNote(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveFrontAppTerminateNote(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    // We add apps when we receive a didActivateApplicationNotification notification, not when we receive an apps launched, because any app will have an apps launched notification.
    // But we are only interested in apps that have windows. We think that since an app can be activated, it must have a window, and subscribing to its window event makes sense and is likely to work, even if it requires multiple retries to subscribe.
    // I'm not very sure if there is an edge case, but so far testing down the line has not revealed it.
    // When we receive the didActivateApplicationNotification notification, NSRunningApplication.isActive=true, even if the app is not the frontmost window anymore.
    // If we go to add the application when we receive the message of apps launched, at this time NSRunningApplication.isActive may be false, and try axUiElement.windows() may also throw an exception.
    // For those background applications, we don't receive notifications of didActivateApplicationNotification until they have their own window. For example, those menu bar applications.
    @objc static func receiveFrontAppChangeNote(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            debugPrint("OS event", notification.name.rawValue, application.bundleIdentifier, application.processIdentifier)
            guard let app = (Applications.list.first { application.processIdentifier == $0.pid }) else {
                debugPrint("add running application", application.bundleIdentifier, application.processIdentifier)
                application.notification = notification.name
                Applications.addRunningApplications([application])
                return
            }
            guard let win = (Windows.list.first { application.processIdentifier == $0.application.runningApplication.processIdentifier && !$0.isWindowlessApp }) else {
                app.hasBeenActiveOnce = true
                app.runningApplication.notification = notification.name
                app.observeNewWindows()
                return
            }
        }
    }

    @objc static func receiveFrontAppLaunchNote(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            debugPrint("OS event", notification.name.rawValue, application.bundleIdentifier, application.processIdentifier)
            guard let app = (Applications.list.first { application.processIdentifier == $0.pid }) else {
                debugPrint("add running application", notification.name.rawValue, application.bundleIdentifier, application.processIdentifier)
                application.notification = notification.name
                Applications.addRunningApplications([application])
                return
            }
        }
    }

    @objc static func receiveFrontAppTerminateNote(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            debugPrint("OS event", notification.name.rawValue, application.bundleIdentifier, application.processIdentifier)
            if let app = (Applications.list.first { application.processIdentifier == $0.pid }) {
                debugPrint("remove running application", application.bundleIdentifier, application.processIdentifier)
                Applications.removeRunningApplications([application])
            }
        }
    }
}
