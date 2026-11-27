import Foundation
import AVFoundation
import CoreAudio
import QuartzCore

/// 只在本地录制期间采集麦克风；不录制时完全停止，避免麦克风常驻。
final class AudioCaptureController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "liveface.audio")
    private var configured = false
    private var audioOutput: AVCaptureAudioDataOutput?
    private let settingsLock = NSLock()
    private var selectedMicrophoneID: String?

    var onSample: ((CMSampleBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    private var lastLevelAt: Double = 0

    func setMicrophone(id: String?) {
        settingsLock.lock()
        selectedMicrophoneID = id
        settingsLock.unlock()
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.configured = false
        }
    }

    private var currentMicrophoneID: String? {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return selectedMicrophoneID
    }

    static func audioDevices() -> [CaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .microphone, .external
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .audio, position: .unspecified
        )
        return discovery.devices.map {
            CaptureDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    func start(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            configureAndStart(completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { completion(false); return }
                    if granted {
                        self.configureAndStart(completion)
                    } else {
                        completion(false)
                    }
                }
            }
        default:
            completion(false)
        }
    }

    private func configureAndStart(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                for input in self.session.inputs {
                    self.session.removeInput(input)
                }
                for output in self.session.outputs {
                    self.session.removeOutput(output)
                }
                let wanted = self.currentMicrophoneID
                let device = wanted.flatMap { AVCaptureDevice(uniqueID: $0) }
                    ?? AVCaptureDevice.default(for: .audio)
                guard let device,
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                self.session.addInput(input)

                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                }
                self.audioOutput = output
                self.session.commitConfiguration()
                self.configured = true
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
            let ok = self.session.isRunning
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        if now - lastLevelAt > 0.05, let level = Self.audioLevel(from: sampleBuffer) {
            lastLevelAt = now
            onLevel?(level)
        }
        onSample?(sampleBuffer)
    }

    /// 0..1 的 RMS 电平，够驱动一个轻量电平表；不用于音频分析。
    static func audioLevel(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bytesPerSample = max(1, bits / 8)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPtr
        ) == noErr, let dataPtr else { return nil }

        let available = min(totalLength, frames * channels * bytesPerSample)
        let count = available / bytesPerSample
        guard count > 0 else { return nil }

        var sum = 0.0
        if isFloat {
            let p = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                let v = Double(p[i])
                sum += v * v
            }
        } else if bits == 16 {
            let p = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: Int16.self)
            for i in 0..<count {
                let v = Double(p[i]) / 32768.0
                sum += v * v
            }
        } else if bits == 32 {
            let p = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: Int32.self)
            for i in 0..<count {
                let v = Double(p[i]) / 2147483648.0
                sum += v * v
            }
        } else {
            return nil
        }

        let rms = sqrt(sum / Double(count))
        return Float(min(1.0, max(0.0, rms * 8.0)))
    }
}
