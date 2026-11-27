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
    @Published var headOffsetX = 0
    @Published var maxRecordingMinutes = 0 {
        didSet { UserDefaults.standard.set(maxRecordingMinutes, forKey: "lf_max_record_minutes") }
    }
    @Published var selectedCameraID = ""
    @Published var selectedMicrophoneID = ""
    @Published var cameraDevices: [CaptureDevice] = []
    @Published var microphoneDevices: [CaptureDevice] = []
    @Published var captureDirectory: URL = AppModel.defaultCaptureDirectory() {
        didSet {
            UserDefaults.standard.set(captureDirectory.path, forKey: "lf_capture_dir")
            refreshRecentCaptures()
        }
    }
    @Published var isRecording = false
    @Published var recordingWithAudio = false
    @Published var micLevel: Float = 0
    @Published var recordSeconds = 0
    @Published var recordCountdown: Int?
    @Published var videoBitrateMbps = 8 {
        didSet { UserDefaults.standard.set(videoBitrateMbps, forKey: "lf_video_bitrate") }
    }
    @Published var recordMicrophone = true {
        didSet { UserDefaults.standard.set(recordMicrophone, forKey: "lf_record_mic") }
    }
    @Published var recordCountdownSeconds = 0 {
        didSet {
            UserDefaults.standard.set(recordCountdownSeconds, forKey: "lf_record_countdown")
            if recordCountdown != nil {
                cancelRecordCountdown()
            }
        }
    }
    @Published var lastCaptureURL: URL?
    @Published var recentCaptures: [CaptureItem] = []
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
    private let audioCapture = AudioCaptureController()
    private var startingRecording = false
    private var recordStartedAt: Date?
    private var countdownTimer: Timer?

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
        recordCountdownSeconds = UserDefaults.standard.integer(forKey: "lf_record_countdown")
        let savedBitrate = UserDefaults.standard.integer(forKey: "lf_video_bitrate")
        if [4, 8, 12].contains(savedBitrate) { videoBitrateMbps = savedBitrate }
        if UserDefaults.standard.object(forKey: "lf_record_mic") != nil {
            recordMicrophone = UserDefaults.standard.bool(forKey: "lf_record_mic")
        }
        let savedMax = UserDefaults.standard.integer(forKey: "lf_max_record_minutes")
        if [1, 5, 10, 30].contains(savedMax) { maxRecordingMinutes = savedMax }
        camera.backend = backend
        camera.updateSettings(delayMs: delayMs, qualityPct: qualityPct)
        audioCapture.onSample = { [weak self] sampleBuffer in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.mediaCapture.appendAudio(sampleBuffer)
            }
        }
        audioCapture.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.micLevel = level
            }
        }
        selectedCameraID = UserDefaults.standard.string(forKey: "lf_camera_id") ?? ""
        selectedMicrophoneID = UserDefaults.standard.string(forKey: "lf_mic_id") ?? ""
        camera.setCamera(id: selectedCameraID.isEmpty ? nil : selectedCameraID)
        audioCapture.setMicrophone(id: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID)
        wireCamera()
        observeBackend()
        refreshDevices()
        refreshRecentCaptures()
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
        cancelRecordCountdown()
        audioCapture.stop()
        micLevel = 0
        if isRecording {
            isRecording = false
            recordingWithAudio = false
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
                    if let value = state.settings.head_offset_x { self.headOffsetX = value }
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
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
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
            if granted {
                DispatchQueue.main.async { self?.refreshDevices() }
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
                self.mediaCapture.append(image: image, hostTime: capture)
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
                self.cancelRecordCountdown()
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
            let elapsed = Date().timeIntervalSince(started)
            recordSeconds = max(0, Int(elapsed))
            if maxRecordingMinutes > 0,
               elapsed >= Double(maxRecordingMinutes * 60) {
                stopRecording()
                flash("已达到最长录制时长，已保存")
            }
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

    func refreshDevices() {
        let cameras = CameraController.videoDevices()
        let microphones = AudioCaptureController.audioDevices()
        cameraDevices = cameras
        microphoneDevices = microphones
        if !isRunning,
           !selectedCameraID.isEmpty,
           !cameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = ""
            camera.setCamera(id: nil)
            UserDefaults.standard.set("", forKey: "lf_camera_id")
        }
        if !isRecording,
           !selectedMicrophoneID.isEmpty,
           !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = ""
            audioCapture.setMicrophone(id: nil)
            UserDefaults.standard.set("", forKey: "lf_mic_id")
        }
    }

    func setCameraDevice(_ id: String) {
        guard !isRunning else {
            flash("请先停止直播，再切换摄像头")
            return
        }
        guard id != selectedCameraID else { return }
        selectedCameraID = id
        camera.setCamera(id: id.isEmpty ? nil : id)
        UserDefaults.standard.set(id, forKey: "lf_camera_id")
        flash(id.isEmpty ? "摄像头：系统默认" : "摄像头已选择")
    }

    func setMicrophoneDevice(_ id: String) {
        guard !isRecording else {
            flash("请先停止录制，再切换麦克风")
            return
        }
        guard id != selectedMicrophoneID else { return }
        selectedMicrophoneID = id
        audioCapture.setMicrophone(id: id.isEmpty ? nil : id)
        UserDefaults.standard.set(id, forKey: "lf_mic_id")
        flash(id.isEmpty ? "麦克风：系统默认" : "麦克风已选择")
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

    func setHeadOffsetX(_ value: Int) {
        let v = min(20, max(-20, value))
        guard v != headOffsetX else { return }
        headOffsetX = v
        backend.setHeadParameters(offsetX: v)
    }

    func applyHeadPreset(_ preset: HeadPreset) {
        let values: (Int, Int, Int)
        let name: String
        switch preset {
        case .natural:
            values = (70, 98, 0)
            name = "自然"
        case .balanced:
            values = (90, 100, 0)
            name = "均衡"
        case .strong:
            values = (100, 104, 0)
            name = "明显"
        }
        headStrength = values.0
        headScale = values.1
        headOffsetY = values.2
        headOffsetX = 0
        backend.setHeadParameters(
            strength: values.0, scale: values.1, offsetY: values.2, offsetX: 0
        )
        flash("换头预设：\(name)")
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

    func refreshRecentCaptures() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: captureDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            recentCaptures = []
            return
        }
        let items: [CaptureItem] = urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard url.lastPathComponent.hasPrefix("LiveFace_"),
                  ext == "png" || ext == "mp4" else { return nil }
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            return CaptureItem(
                url: url,
                date: values?.contentModificationDate ?? .distantPast,
                size: Int64(values?.fileSize ?? 0)
            )
        }
        recentCaptures = Array(items.sorted { $0.date > $1.date }.prefix(5))
    }

    func openCapture(_ item: CaptureItem) {
        NSWorkspace.shared.open(item.url)
    }

    func revealCapture(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func deleteCapture(_ item: CaptureItem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这个文件？"
        alert.informativeText = item.name
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.removeItem(at: item.url)
            if lastCaptureURL == item.url { lastCaptureURL = nil }
            refreshRecentCaptures()
            flash("已删除：\(item.name)")
        } catch {
            alertMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func captureScreenshot() {
        guard let image = displayedImage else {
            alertMessage = "还没有换脸画面，请先开始直播。"
            return
        }
        do {
            let url = try MediaCapture.saveScreenshot(image, in: captureDirectory)
            lastCaptureURL = url
            refreshRecentCaptures()
            flash("已保存截图：\(url.lastPathComponent)")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
            return
        }
        if recordCountdown != nil {
            cancelRecordCountdown()
            return
        }
        guard isRunning, displayedImage != nil else {
            alertMessage = "开始直播后才能录制。请先点击「开始直播」。"
            return
        }
        if recordCountdownSeconds > 0 {
            beginRecordCountdown()
        } else {
            startRecording()
        }
    }

    private func beginRecordCountdown() {
        cancelRecordCountdown()
        recordCountdown = recordCountdownSeconds
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.isRunning else {
                timer.invalidate()
                self.countdownTimer = nil
                self.recordCountdown = nil
                return
            }
            if let value = self.recordCountdown, value > 1 {
                self.recordCountdown = value - 1
            } else {
                timer.invalidate()
                self.countdownTimer = nil
                self.recordCountdown = nil
                self.startRecording()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    func cancelRecordCountdown() {
        let hadCountdown = recordCountdown != nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        recordCountdown = nil
        if hadCountdown {
            flash("已取消录制倒计时")
        }
    }

    private func startRecording() {
        guard !isRecording, !startingRecording else { return }
        guard isRunning, let image = displayedImage else {
            alertMessage = "开始直播后才能录制。请先点击「开始直播」。"
            return
        }
        startingRecording = true

        let begin: (Bool) -> Void = { [weak self] withAudio in
            guard let self else { return }
            self.startingRecording = false
            guard self.isRunning else {
                self.audioCapture.stop()
                self.alertMessage = "摄像头已停止，录制取消。"
                return
            }
            do {
                let url = try self.mediaCapture.start(
                    image: image,
                    in: self.captureDirectory,
                    withAudio: withAudio,
                    videoBitrate: self.videoBitrateMbps * 1_000_000
                )
                self.recordingWithAudio = withAudio
                self.isRecording = true
                self.micLevel = 0
                self.recordStartedAt = Date()
                self.recordSeconds = 0
                self.lastCaptureURL = url
                self.flash(
                    withAudio
                    ? "开始录制（含麦克风）：\(url.lastPathComponent)"
                    : "开始录制（无麦克风）：\(url.lastPathComponent)"
                )
            } catch {
                self.audioCapture.stop()
                self.recordingWithAudio = false
                self.alertMessage = error.localizedDescription
            }
        }

        guard recordMicrophone else {
            begin(false)
            flash("录制麦克风已关闭：视频无音频")
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized || status == .notDetermined {
            audioCapture.start { ok in
                if !ok {
                    self.flash("麦克风不可用：只录制画面")
                } else {
                    self.refreshDevices()
                }
                begin(ok)
            }
        } else {
            begin(false)
            flash("麦克风未授权：只录制画面；可在系统设置开启")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingWithAudio = false
        micLevel = 0
        recordStartedAt = nil
        audioCapture.stop()
        mediaCapture.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.lastCaptureURL = url
                self.refreshRecentCaptures()
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

// MARK: - 最近文件

struct CaptureItem: Identifiable {
    let url: URL
    let date: Date
    let size: Int64

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isVideo: Bool { url.pathExtension.lowercased() == "mp4" }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

extension AppModel {
    enum HeadPreset {
        case natural
        case balanced
        case strong
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
