import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import QuartzCore
import Foundation

/// 采集摄像头 → JPEG → 本地服务换脸 → 按固定延迟上屏。
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false

    let session = AVCaptureSession()
    let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

    private let queue = DispatchQueue(label: "liveface.camera")
    private let stateLock = NSLock()
    private let settingsLock = NSLock()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var videoOutput: AVCaptureVideoDataOutput?
    private var configured = false
    private var running = false
    private var inFlight = 0
    private var lastDisplayed: Double = 0
    private var delayMs: Double = 0
    private var quality: Double = 0.72
    private var demoTimer: Timer?
    private var lastPreviewAt: Double = 0

    weak var backend: BackendClient?
    var onPreview: ((CGImage) -> Void)?
    var onDisplay: ((CGImage, Double) -> Void)?
    var onMetrics: ((Double, Double) -> Void)?
    var onDrop: (() -> Void)?
    var onSkip: (() -> Void)?
    var onRunningChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - 设置

    func updateSettings(delayMs: Double, qualityPct: Double) {
        settingsLock.lock()
        self.delayMs = delayMs
        self.quality = min(0.95, max(0.4, qualityPct / 100.0))
        settingsLock.unlock()
    }

    private var currentDelay: Double {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return delayMs / 1000.0
    }

    private var currentQuality: Double {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return quality
    }

    // MARK: - 启停

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("[camera] start demo=\(isDemo) auth=\(status.rawValue)")
        if isDemo {
            startDemo()
            return
        }
        switch status {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                print("[camera] requestAccess granted=\(granted)")
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.permissionDenied = true
                        self.onError?("摄像头权限被拒绝。请在「系统设置 → 隐私与安全性 → 摄像头」中允许 LiveFace。")
                    }
                }
            }
        default:
            permissionDenied = true
            onError?("摄像头不可用。请在「系统设置 → 隐私与安全性 → 摄像头」中允许 LiveFace。")
        }
    }

    func stop() {
        demoTimer?.invalidate()
        demoTimer = nil
        queue.async {
            self.setState(running: false)
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.onRunningChanged?(false)
            }
        }
    }

    private func configureAndStart() {
        print("[camera] configureAndStart")
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                if self.session.canSetSessionPreset(.hd1280x720) {
                    self.session.sessionPreset = .hd1280x720
                } else {
                    self.session.sessionPreset = .high
                }

                guard let device = AVCaptureDevice.default(for: .video) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.onError?("没有找到可用的摄像头") }
                    return
                }
                guard let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.onError?("无法读取摄像头") }
                    return
                }
                self.session.addInput(input)

                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                }
                self.videoOutput = output
                if let connection = output.connection(with: .video) {
                    if connection.isVideoMirroringSupported {
                        connection.isVideoMirrored = false
                    }
                }
                self.session.commitConfiguration()
                self.configured = true
            }

            self.setState(running: true)
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
                self.onRunningChanged?(true)
            }
        }
    }

    // MARK: - 采集

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isActive() else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let capture = CACurrentMediaTime()
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        // 原始画面缩略图（约 10fps），直接给 SwiftUI 显示，避免 AppKit 预览层
        if capture - lastPreviewAt > 0.1 {
            lastPreviewAt = capture
            let preview = cgImage
            DispatchQueue.main.async { self.onPreview?(preview) }
        }

        send(image: cgImage, capture: capture)
    }

    /// 演示模式：用测试图模拟摄像头，走完全相同的换脸链路
    private func startDemo() {
        let path = BackendClient.resolveProjectPath() + "/test_assets/target_face.jpg"
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            onError?("演示图片缺失：\(path)")
            return
        }
        setState(running: true)
        DispatchQueue.main.async {
            self.isRunning = true
            self.onRunningChanged?(true)
            self.onPreview?(image)
        }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, self.isActive() else { return }
            self.queue.async {
                self.send(image: image, capture: CACurrentMediaTime())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    private func send(image: CGImage, capture: Double) {
        guard isActive(), let backend else { return }
        if !reserveSlot() {
            DispatchQueue.main.async { self.onSkip?() }
            return
        }
        guard let jpeg = encodeJPEG(image, quality: currentQuality) else {
            releaseSlot()
            return
        }

        backend.sendFrame(jpeg: jpeg, capture: capture) { [weak self] response in
            guard let self else { return }
            self.releaseSlot()

            guard self.isActive() else { return }
            if response.status == 204 {
                DispatchQueue.main.async { self.onDrop?() }
                return
            }
            guard response.status == 200,
                  let data = response.data,
                  let image = self.decodeJPEG(data) else {
                return
            }

            let e2e = (CACurrentMediaTime() - capture) * 1000
            DispatchQueue.main.async {
                self.onMetrics?(response.processMs, e2e)
                let target = capture + self.currentDelay
                let wait = target - CACurrentMediaTime()
                if wait > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                        self.present(image, capture: capture)
                    }
                } else {
                    self.present(image, capture: capture)
                }
            }
        }
    }

    private func present(_ image: CGImage, capture: Double) {
        guard isActive() else { return }
        if capture <= lastDisplayed { return }
        lastDisplayed = capture
        onDisplay?(image, capture)
    }

    // MARK: - 状态锁

    private func isActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func setState(running value: Bool) {
        stateLock.lock()
        running = value
        if !value { inFlight = 0 }
        stateLock.unlock()
    }

    private func reserveSlot() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if inFlight >= 2 { return false }
        inFlight += 1
        return true
    }

    private func releaseSlot() {
        stateLock.lock()
        inFlight = max(0, inFlight - 1)
        stateLock.unlock()
    }

    // MARK: - 编解码

    private func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
