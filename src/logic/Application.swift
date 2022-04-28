import Cocoa
import ApplicationServices.HIServices.AXNotificationConstants

class Application: NSObject {
    // kvObservers should be listed first, so it gets deinit'ed first; otherwise it can crash
    var kvObservers: [NSKeyValueObservation]?
    var runningApplication: NSRunningApplication
    var axUiElement: AXUIElement?
    var axObserver: AXObserver?
    var isReallyFinishedLaunching = false
    var isHidden: Bool!
    var hasBeenActiveOnce: Bool!
    var icon: NSImage?
    var dockLabel: String?
    var pid: pid_t!
    var wasLaunchedBeforeAltTab = false
    var focusedWindow: Window? = nil

    static func notifications(_ app: NSRunningApplication) -> [String] {
        let n = [
            kAXApplicationActivatedNotification,
            kAXMainWindowChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowCreatedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
            kAXFocusedUIElementChangedNotification,
        ]
        // workaround: some apps exhibit bugs when we subscribe to its kAXFocusedUIElementChangedNotification
        // we don't know what's happening; we avoid this subscription to make these app usable
        if app.bundleIdentifier == "edu.stanford.protege" ||
               app.bundleIdentifier?.range(of: "^com\\.install4j\\..+?$", options: .regularExpression) != nil ||
               app.bundleIdentifier?.range(of: "^com\\.live2d\\.cubism\\..+?$", options: .regularExpression) != nil ||
               app.bundleIdentifier?.range(of: "^com\\.(jetbrains\\.|google\\.android\\.studio).*?$", options: .regularExpression) != nil {
            return n.filter { $0 != kAXFocusedUIElementChangedNotification }
        }
        return n
    }

    init(_ runningApplication: NSRunningApplication, _ wasLaunchedBeforeAltTab: Bool = false) {
        self.runningApplication = runningApplication
        self.wasLaunchedBeforeAltTab = wasLaunchedBeforeAltTab
        pid = runningApplication.processIdentifier
        super.init()
        isHidden = runningApplication.isHidden
        hasBeenActiveOnce = runningApplication.isActive
        icon = runningApplication.icon
        addAndObserveWindows()
        kvObservers = [
            runningApplication.observe(\.isFinishedLaunching, options: [.new]) { [weak self] _, _ in
                guard let self = self else { return }
                self.addAndObserveWindows()
            },
            runningApplication.observe(\.activationPolicy, options: [.new]) { [weak self] _, _ in
                guard let self = self else { return }
                if self.runningApplication.activationPolicy != .regular {
                    self.removeWindowslessAppWindow()
                }
                self.addAndObserveWindows()
            },
        ]
    }

    deinit {
        debugPrint("Deinit app", runningApplication.bundleIdentifier ?? runningApplication.bundleURL ?? "nil")
    }

    func removeWindowslessAppWindow() {
        if let windowlessAppWindow = (Windows.list.firstIndex { $0.isWindowlessApp == true && $0.application.pid == pid }) {
            Windows.list.remove(at: windowlessAppWindow)
            App.app.refreshOpenUi()
        }
    }

    func addAndObserveWindows() {
        if runningApplication.activationPolicy != .prohibited && axUiElement == nil {
            axUiElement = AXUIElementCreateApplication(pid)
            AXObserverCreate(pid, axObserverCallback, &axObserver)
            debugPrint("Adding app", pid ?? "nil", runningApplication.bundleIdentifier ?? "nil")
            observeEvents()
        }
    }

    func observeNewWindows(_ group: DispatchGroup? = nil) {
        if runningApplication.isFinishedLaunching && runningApplication.activationPolicy != .prohibited {
            retryAxCallUntilTimeout(group, 5) { [weak self] in
                guard let self = self, let axWindows_ = try self.axUiElement!.windows() else { throw AxError.runtimeError }
                if axWindows_.count > 0 {
                    // bug in macOS: sometimes the OS returns multiple duplicate windows (e.g. Mail.app starting at login)
                    let axWindows = try Array(Set(axWindows_)).compactMap {
                        if let wid = try $0.cgWindowId() {
                            let title = try $0.title()
                            let subrole = try $0.subrole()
                            let role = try $0.role()
                            let size = try $0.size()
                            let level = try wid.level()
                            if AXUIElement.isActualWindow(self.runningApplication, wid, level, title, subrole, role, size) {
                                return ($0, wid, title, try $0.isFullscreen(), try $0.isMinimized(), try $0.position(), size)
                            }
                        }
                        return nil
                    } as [(AXUIElement, CGWindowID, String?, Bool, Bool, CGPoint?, CGSize?)]
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        var windows = self.addWindows(axWindows)
                        if let window = self.addWindowslessAppsIfNeeded() {
                            windows.append(contentsOf: window)
                        }
                        App.app.refreshOpenUi(windows)
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        let window = self.addWindowslessAppsIfNeeded()
                        App.app.refreshOpenUi(window)
                    }
                    // workaround: some apps launch but have no window ready instantly. It's very unlikely an app would launch with no window
                    // so we retry until timeout, in those rare cases (e.g. Bear.app)
                    // we only do this for active app, to avoid wasting CPU, with the trade-off of maybe missing some windows
                    if group == nil && self.runningApplication.notification == NSWorkspace.didActivateApplicationNotification {
                        throw AxError.runtimeError
                    }
                }
            }
        }
    }

    private func addWindows(_ axWindows: [(AXUIElement, CGWindowID, String?, Bool, Bool, CGPoint?, CGSize?)]) -> [Window] {
        let windows: [Window] = axWindows.compactMap { (axUiElement, wid, axTitle, isFullscreen, isMinimized, position, size) in
            if (Windows.list.firstIndex { $0.isEqualRobust(axUiElement, wid) }) == nil {
                let window = Window(axUiElement, self, wid, axTitle, isFullscreen, isMinimized, position, size)
                Windows.appendAndUpdateFocus(window)
                return window
            }
            return nil
        }
        if App.app.appIsBeingUsed {
            Windows.cycleFocusedWindowIndex(windows.count)
        }
        return windows
    }

    func getOtherSpaceWindows(_ windowsOnlyOnOtherSpaces: [CGWindowID]) -> [Window] {
        var otherSpaceWindows: [Window] = []
        for winId in windowsOnlyOnOtherSpaces {
            let cgWinArray = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionIncludingWindow], winId) as! [CGWindow]
            // get current app's windows only on other space
            guard runningApplication.processIdentifier == cgWinArray.first!.ownerPID()
                          && cgWinArray.first!.id() != nil
                          && cgWinArray.first!.isNotMenubarOrOthers()
                          && cgWinArray.first!.bounds() != nil
                          && CGRect(dictionaryRepresentation: cgWinArray.first!.bounds()!)!.width > 100
                          && CGRect(dictionaryRepresentation: cgWinArray.first!.bounds()!)!.height > 100
                    else { continue }
            guard let capture = CGWindowListCreateImage(CGRect.null, .optionIncludingWindow, cgWinArray.first!.id()!, .boundsIgnoreFraming) else { continue }
            let win = Window(self, cgWinArray.first!)
            Windows.appendAndUpdateFocus(win)
            otherSpaceWindows.append(win)
        }
        return otherSpaceWindows
    }

    func addOtherSpaceWindows(_ windowsOnlyOnOtherSpaces: [CGWindowID]) {
        if runningApplication.isFinishedLaunching && runningApplication.activationPolicy != .prohibited {
            retryAxCallUntilTimeout { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    var windows = self.getOtherSpaceWindows(windowsOnlyOnOtherSpaces)
                    if let window = self.addWindowslessAppsIfNeeded() {
                        windows.append(contentsOf: window)
                    }
                    App.app.refreshOpenUi(windows)
                }
            }
        }
    }

    func addWindowslessAppsIfNeeded() -> [Window]? {
        if !Preferences.hideWindowlessApps &&
               runningApplication.activationPolicy == .regular &&
               !runningApplication.isTerminated &&
               (Windows.list.firstIndex { $0.application.pid == pid }) == nil {
            let window = Window(self)
            Windows.appendAndUpdateFocus(window)
            return [window]
        }
        return nil
    }

    private func observeEvents() {
        guard let axObserver = axObserver else { return }
        for notification in Application.notifications(runningApplication) {
            retryAxCallUntilTimeout { [weak self] in
                guard let self = self else { return }
                try self.axUiElement!.subscribeToNotification(axObserver, notification, {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        // some apps have `isFinishedLaunching == true` but are actually not finished, and will return .cannotComplete
                        // we consider them ready when the first subscription succeeds, and list their windows again at that point
                        if !self.isReallyFinishedLaunching {
                            self.isReallyFinishedLaunching = true
                            self.observeNewWindows()
                        }
                    }
                }, self.runningApplication)
            }
        }
        CFRunLoopAddSource(BackgroundWork.accessibilityEventsThread.runLoop, AXObserverGetRunLoopSource(axObserver), .defaultMode)
    }
}
