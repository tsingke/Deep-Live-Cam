import SwiftUI
import AppKit
import ImageIO
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let backend = BackendClient()
    private lazy var model = AppModel(backend: backend)
    private var window: NSWindow?

    // MARK: - 生命周期

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        NSSetUncaughtExceptionHandler { exception in
            let project = BackendClient.resolveProjectPath()
            let text = "\(Date())\n[\(exception.name.rawValue)] \(exception.reason ?? "nil")\n"
                + exception.callStackSymbols.joined(separator: "\n")
            try? text.write(
                toFile: project + "/logs/native-crash.log",
                atomically: true, encoding: .utf8
            )
            try? text.write(
                toFile: "/tmp/LiveFace-crash.log",
                atomically: true, encoding: .utf8
            )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        showMainWindow()

        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let path = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.writeSnapshot(to: path)
                NSApp.terminate(nil)
            }
        }

        if args.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NotificationCenter.default.post(name: .liveFaceOpenSettings, object: nil)
            }
        }

        if let index = args.firstIndex(of: "--snapshot-settings"), index + 1 < args.count {
            let path = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if let sheet = self.window?.attachedSheet {
                    self.capture(window: sheet, to: path)
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let window {
            UserDefaults.standard.set(
                NSStringFromRect(window.frame), forKey: "lf_main_frame"
            )
        }
        model.shutdown()
    }

    // MARK: - 主窗口

    private func showMainWindow() {
        if window == nil {
            let root = ContentView()
                .environmentObject(backend)
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 680)

            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "实时换脸"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.contentView = hosting
            window.setContentSize(NSSize(width: 1220, height: 780))
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            if let saved = UserDefaults.standard.string(forKey: "lf_main_frame"),
               !saved.isEmpty {
                let frame = NSRectFromString(saved)
                if frame.width >= 1040, frame.height >= 680 {
                    window.setFrame(window.constrainFrameRect(frame, to: nil), display: false)
                } else {
                    window.center()
                }
            } else {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            self.window = window
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: "实时换脸", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "实时换脸")
        appMenu.addItem(
            withTitle: "关于实时换脸",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let settings = appMenu.addItem(
            withTitle: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "退出实时换脸", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appItem.submenu = appMenu

        let liveItem = NSMenuItem(title: "直播", action: nil, keyEquivalent: "")
        mainMenu.addItem(liveItem)
        let liveMenu = NSMenu(title: "直播")
        let toggle = liveMenu.addItem(
            withTitle: "开始 / 停止直播",
            action: #selector(toggleCamera),
            keyEquivalent: ""
        )
        toggle.target = self
        let output = liveMenu.addItem(
            withTitle: "打开输出窗口",
            action: #selector(showOutput),
            keyEquivalent: "O"
        )
        output.keyEquivalentModifierMask = [.command, .shift]
        output.target = self

        liveMenu.addItem(.separator())
        let screenshot = liveMenu.addItem(
            withTitle: "截图",
            action: #selector(captureScreenshot),
            keyEquivalent: "s"
        )
        screenshot.keyEquivalentModifierMask = [.command]
        screenshot.target = self

        let record = liveMenu.addItem(
            withTitle: "开始 / 停止录制",
            action: #selector(toggleRecording),
            keyEquivalent: "r"
        )
        record.keyEquivalentModifierMask = [.command]
        record.target = self

        liveMenu.addItem(.separator())
        let chooseDir = liveMenu.addItem(
            withTitle: "选择保存目录…",
            action: #selector(chooseCaptureDirectory),
            keyEquivalent: ""
        )
        chooseDir.target = self

        liveItem.submenu = liveMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleCamera() {
        model.toggleCamera()
    }

    @objc private func showOutput() {
        model.showOutputWindow()
    }

    @objc private func captureScreenshot() {
        model.captureScreenshot()
    }

    @objc private func toggleRecording() {
        model.toggleRecording()
    }

    @objc private func chooseCaptureDirectory() {
        model.chooseCaptureDirectory()
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .liveFaceOpenSettings, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 快照（调试）

    @MainActor
    private func writeSnapshot(to path: String) {
        print("[snapshot] windows=\(NSApp.windows.map { "\($0.title)|visible=\($0.isVisible)|\($0.frame)" })")
        let windows = NSApp.windows.filter {
            $0.isVisible && $0.contentView != nil && $0.frame.width > 300
        }
        for window in windows {
            let isOutput = window.title.contains("输出")
            let target = isOutput
                ? path.replacingOccurrences(of: ".png", with: ".output.png")
                : path
            capture(window: window, to: target)
        }
    }

    @MainActor
    private func capture(window: NSWindow, to path: String) {
        guard let view = window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
