import SwiftUI
import Combine
import AppKit
import QuartzCore
import AVFoundation

final class AppModel: ObservableObject {
    let backend: BackendClient
    let camera = CameraController()

    @Published var displayedImage: CGImage?
    @Published var previewImage: CGImage?
    @Published var isRunning = false
    @Published var fps: Double = 0
    @Published var latencyMs: Double?
    @Published var displayDelayMs: Double?
    @Published var dropped = 0
    @Published var skipped = 0
    @Published var alertMessage: String?
    @Published var cameraPermissionIssue = false
    @Published var detectInterval = 3
    @Published var swapCount = 1
    @Published var transientMessage: String?
    @Published var delayMs: Double = 0 {
        didSet {
            UserDefaults.standard.set(delayMs, forKey: "lf_delay")
            camera.updateSettings(delayMs: delayMs, qualityPct: qualityPct)
        }
    }
    @Published var qualityPct: Double = 72 {
        didSet {
            UserDefaults.standard.set(qualityPct, forKey: "lf_quality")
            camera.updateSettings(delayMs: delayMs, qualityPct: qualityPct)
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var outputController: OutputWindowController?
    private var shownTimes: [Double] = []
    private var e2eSamples: [Double] = []
    private var displaySamples: [Double] = []
    private var fpsTimer: Timer?
    private var keyMonitor: Any?
    private var pendingStart = false
    private let demoMode = ProcessInfo.processInfo.arguments.contains("--demo")
    private let cameraTestMode = ProcessInfo.processInfo.arguments.contains("--camera")
    private var demoAutoStarted = false
    private var cameraAutoStarted = false
    private var toastWorkItem: DispatchWorkItem?

    var isDemo: Bool { camera.isDemo }

    init(backend: BackendClient) {
        self.backend = backend
        if let saved = UserDefaults.standard.object(forKey: "lf_delay") as? Double {
            delayMs = saved
        }
        if let saved = UserDefaults.standard.object(forKey: "lf_quality") as? Double {
            qualityPct = saved
        }
        camera.backend = backend
        camera.updateSettings(delayMs: delayMs, qualityPct: qualityPct)
        wireCamera()
        observeBackend()
    }

    // MARK: - 服务

    func startServices() {
        print("[app] startServices")
        requestCameraPermissionIfNeeded()
        backend.start()
        installKeyMonitor()
        guard fpsTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tickMetrics()
        }
        RunLoop.main.add(timer, forMode: .common)
        fpsTimer = timer
    }

    func shutdown() {
        camera.stop()
        outputController?.close()
        outputController = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        fpsTimer?.invalidate()
        fpsTimer = nil
        toastWorkItem?.cancel()
        backend.stopIfStarted()
    }

    private func observeBackend() {
        backend.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, let state else { return }
                if state.settings.detect_interval != self.detectInterval {
                    self.detectInterval = state.settings.detect_interval
                }
                if state.settings.swap_count != self.swapCount {
                    self.swapCount = state.settings.swap_count
                }
                if state.ready, self.pendingStart {
                    self.pendingStart = false
                    self.startCamera()
                }
                if state.ready, self.demoMode, !self.demoAutoStarted {
                    self.demoAutoStarted = true
                    self.startCamera()
                    if ProcessInfo.processInfo.arguments.contains("--output") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            self.showOutputWindow()
                        }
                    }
                }
                if state.ready, self.cameraTestMode, !self.demoMode, !self.cameraAutoStarted {
                    self.cameraAutoStarted = true
                    self.startCamera()
                }
            }
            .store(in: &cancellables)

        backend.$lastError
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.alertMessage = message
            }
            .store(in: &cancellables)
    }

    // MARK: - 摄像头

    var isReady: Bool { backend.state?.ready == true }

    /// 启动时主动请求相机权限；新 Bundle ID 首次运行会弹出干净的授权窗口。
    private func requestCameraPermissionIfNeeded() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("[permission] camera status=\(status.rawValue)")
        guard status == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            print("[permission] camera granted=\(granted)")
            let path = BackendClient.resolveProjectPath() + "/logs/camera-permission.log"
            let line = "\(Date()) granted=\(granted)\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    func toggleCamera() {
        if isRunning {
            camera.stop()
            return
        }
        if isReady {
            startCamera()
        } else {
            pendingStart = true
            backend.ensureBackend()
            alertMessage = "换脸服务正在启动/加载模型，就绪后会自动开始。"
        }
    }

    private func startCamera() {
        print("[app] startCamera")
        resetStats()
        pendingStart = false
        previewImage = nil
        camera.updateSettings(delayMs: delayMs, qualityPct: qualityPct)
        camera.start()
    }

    private func wireCamera() {
        camera.onPreview = { [weak self] image in
            self?.previewImage = image
        }
        camera.onDisplay = { [weak self] image, capture in
            guard let self else { return }
            self.displayedImage = image
            self.outputController?.update(image)
            let now = CACurrentMediaTime()
            self.shownTimes.append(now)
            self.displaySamples.append((now - capture) * 1000)
            if self.displaySamples.count > 90 {
                self.displaySamples.removeFirst(self.displaySamples.count - 90)
            }
        }
        camera.onMetrics = { [weak self] _, e2e in
            guard let self else { return }
            self.e2eSamples.append(e2e)
            if self.e2eSamples.count > 90 {
                self.e2eSamples.removeFirst(self.e2eSamples.count - 90)
            }
        }
        camera.onDrop = { [weak self] in self?.dropped += 1 }
        camera.onSkip = { [weak self] in self?.skipped += 1 }
        camera.onRunningChanged = { [weak self] running in
            self?.isRunning = running
            if running { self?.cameraPermissionIssue = false }
            if !running { self?.previewImage = nil }
        }
        camera.onError = { [weak self] message in
            self?.alertMessage = message
            if message.contains("摄像头") { self?.cameraPermissionIssue = true }
        }
    }

    private func resetStats() {
        dropped = 0
        skipped = 0
        shownTimes.removeAll()
        e2eSamples.removeAll()
        displaySamples.removeAll()
        latencyMs = nil
        displayDelayMs = nil
        fps = 0
    }

    private func tickMetrics() {
        let now = CACurrentMediaTime()
        shownTimes.removeAll { now - $0 > 2 }
        fps = Double(shownTimes.count) / 2.0
        latencyMs = percentile(Array(e2eSamples.suffix(30)), 0.5)
        displayDelayMs = percentile(Array(displaySamples.suffix(30)), 0.5)
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    // MARK: - 照片

    func selectPhoto(_ id: String) {
        backend.select(id)
    }

    func selectPhoto(index: Int) {
        guard let photos = backend.state?.photos,
              index >= 0, index < photos.count else { return }
        backend.select(photos[index].id)
    }

    func deletePhoto(_ id: String) {
        backend.deletePhoto(id)
    }

    func upload(_ urls: [URL]) {
        backend.upload(urls: urls) { [weak self] result in
            if case .failure(let error) = result {
                self?.alertMessage = error.localizedDescription
            }
        }
    }

    func setDetectInterval(_ value: Int) {
        guard value != detectInterval else { return }
        detectInterval = value
        backend.setDetectInterval(value)
    }

    func setSwapCount(_ value: Int) {
        guard value != swapCount else { return }
        swapCount = value
        backend.setSwapCount(value)
        flash(value <= 0 ? "已切换：换所有人" : "已切换：同时换 \(value) 人")
    }

    /// 点击画面中的脸：x/y 为相对画面内容的 0–1 坐标。
    func selectTarget(x: Double, y: Double) {
        backend.selectTarget(x: x, y: y) { [weak self] ok, error in
            self?.flash(ok ? "已锁定点击的人物" : (error ?? "未找到可锁定的人脸"))
        }
    }

    func resetTarget() {
        backend.resetTarget { [weak self] _ in
            self?.flash("已恢复自动选择主角")
        }
    }

    private func flash(_ message: String) {
        toastWorkItem?.cancel()
        transientMessage = message
        let item = DispatchWorkItem { [weak self] in
            if self?.transientMessage == message {
                self?.transientMessage = nil
            }
        }
        toastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
    }

    // MARK: - 输出窗口

    func showOutputWindow() {
        if outputController == nil {
            let controller = OutputWindowController()
            controller.onClose = { [weak self] in
                self?.outputController = nil
            }
            outputController = controller
        }
        outputController?.show(image: displayedImage)
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if NSApp.keyWindow?.contentView is OutputView {
                return event
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.isEmpty {
                if event.keyCode == 49 { // Space
                    self.toggleCamera()
                    return nil
                }
                if let characters = event.charactersIgnoringModifiers,
                   let number = Int(characters), number >= 1, number <= 9 {
                    self.selectPhoto(index: number - 1)
                    return nil
                }
            }
            return event
        }
    }
}

// MARK: - 拖拽上传

extension AppModel {
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier("public.file-url") else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, !urls.isEmpty else { return }
            self.upload(urls)
        }
        return true
    }
}
