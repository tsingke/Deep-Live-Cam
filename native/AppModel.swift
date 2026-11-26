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
    @Published var headSwap = false
    @Published var headStrength = 90
    @Published var headScale = 100
    @Published var headOffsetY = 0
    @Published var captureDirectory: URL = AppModel.defaultCaptureDirectory()
    @Published var isRecording = false
    @Published var recordSeconds = 0
    @Published var lastCaptureURL: URL?
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
    private var headSwapDirty = false
    private var headParamsInitialized = false
    private let mediaCapture = MediaCapture()
    private var recordStartedAt: Date?

    var isDemo: Bool { camera.isDemo }

    static func defaultCaptureDirectory() -> URL {
        let fm = FileManager.default
        if let movies = fm.urls(for: .moviesDirectory, in: .userDomainMask).first {
            return movies.appendingPathComponent("LiveFace", isDirectory: true)
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/LiveFace", isDirectory: true)
    }

    init(backend: BackendClient) {
        self.backend = backend
        if let saved = UserDefaults.standard.object(forKey: "lf_delay") as? Double {
            delayMs = saved
        }
        if let saved = UserDefaults.standard.object(forKey: "lf_quality") as? Double {
            qualityPct = saved
        }
        if let saved = UserDefaults.standard.string(forKey: "lf_capture_dir"), !saved.isEmpty {
            captureDirectory = URL(fileURLWithPath: saved, isDirectory: true)
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
        if isRecording {
            isRecording = false
            mediaCapture.finishSynchronously()
        }
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
                if let serverHead = state.settings.head_swap {
                    if self.headSwapDirty {
                        if serverHead == self.headSwap { self.headSwapDirty = false }
                    } else if serverHead != self.headSwap {
                        self.headSwap = serverHead
                    }
                }
                if !self.headParamsInitialized {
                    self.headParamsInitialized = true
                    if let value = state.settings.head_strength { self.headStrength = value }
                    if let value = state.settings.head_scale { self.headScale = value }
                    if let value = state.settings.head_offset_y { self.headOffsetY = value }
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
            if self.isRecording {
                self.mediaCapture.append(image: image, hostTime: now)
            }
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
            guard let self else { return }
            self.isRunning = running
            if running { self.cameraPermissionIssue = false }
            if !running {
                self.previewImage = nil
                if self.isRecording { self.stopRecording() }
            }
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
        if isRecording, let started = recordStartedAt {
            recordSeconds = max(0, Int(Date().timeIntervalSince(started)))
        }
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

    /// 用户自定义：换脸（仅面部） / 换头（发型 + 头部轮廓，实验）。
    func setHeadSwap(_ enabled: Bool) {
        guard enabled != headSwap else { return }
        headSwap = enabled
        headSwapDirty = true
        backend.setHeadSwap(enabled)
        flash(enabled
              ? "换头已开启（实验）：叠加源发型与头部轮廓"
              : "已切回换脸：只替换面部")
    }

    func setHeadStrength(_ value: Int) {
        let v = min(100, max(0, value))
        guard v != headStrength else { return }
        headStrength = v
        backend.setHeadParameters(strength: v)
    }

    func setHeadScale(_ value: Int) {
        let v = min(115, max(85, value))
        guard v != headScale else { return }
        headScale = v
        backend.setHeadParameters(scale: v)
    }

    func setHeadOffsetY(_ value: Int) {
        let v = min(20, max(-20, value))
        guard v != headOffsetY else { return }
        headOffsetY = v
        backend.setHeadParameters(offsetY: v)
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

    // MARK: - 截图 / 录制

    var captureDirectoryDisplay: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = captureDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var recordTimeText: String {
        String(format: "%02d:%02d", recordSeconds / 60, recordSeconds % 60)
    }

    func chooseCaptureDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择截图和录制的保存目录"
        panel.directoryURL = captureDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        captureDirectory = url
        UserDefaults.standard.set(url.path, forKey: "lf_capture_dir")
        flash("保存目录：\(captureDirectoryDisplay)")
    }

    func openCaptureDirectory() {
        try? FileManager.default.createDirectory(
            at: captureDirectory, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(captureDirectory)
    }

    func captureScreenshot() {
        guard let image = displayedImage else {
            alertMessage = "还没有换脸画面，请先开始直播。"
            return
        }
        do {
            let url = try MediaCapture.saveScreenshot(image, in: captureDirectory)
            lastCaptureURL = url
            flash("已保存截图：\(url.lastPathComponent)")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        guard isRunning, let image = displayedImage else {
            alertMessage = "开始直播后才能录制。请先点击「开始直播」。"
            return
        }
        do {
            let url = try mediaCapture.start(image: image, in: captureDirectory)
            mediaCapture.append(image: image, hostTime: CACurrentMediaTime())
            isRecording = true
            recordStartedAt = Date()
            recordSeconds = 0
            lastCaptureURL = url
            flash("开始录制：\(url.lastPathComponent)")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordStartedAt = nil
        mediaCapture.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.lastCaptureURL = url
                self.flash("已保存视频：\(url.lastPathComponent)")
            case .failure(let error):
                self.alertMessage = error.localizedDescription
            }
        }
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
            if modifiers.contains(.command),
               let key = event.charactersIgnoringModifiers?.lowercased() {
                if key == "s" {
                    self.captureScreenshot()
                    return nil
                }
                if key == "r" {
                    self.toggleRecording()
                    return nil
                }
            }
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
