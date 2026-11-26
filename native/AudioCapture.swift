import Foundation
import AVFoundation

/// 只在本地录制期间采集麦克风；不录制时完全停止，避免麦克风常驻。
final class AudioCaptureController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "liveface.audio")
    private var configured = false
    private var audioOutput: AVCaptureAudioDataOutput?

    var onSample: ((CMSampleBuffer) -> Void)?

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
                guard let device = AVCaptureDevice.default(for: .audio),
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
        onSample?(sampleBuffer)
    }
}
