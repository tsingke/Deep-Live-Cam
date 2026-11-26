import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

enum MediaCaptureError: LocalizedError {
    case noFrame
    case cannotCreateDirectory(String)
    case cannotEncodeImage
    case cannotStartWriter(String)
    case recordingNotStarted

    var errorDescription: String? {
        switch self {
        case .noFrame:
            return "还没有换脸画面，请先开始直播。"
        case .cannotCreateDirectory(let path):
            return "无法创建保存目录：\(path)"
        case .cannotEncodeImage:
            return "截图编码失败。"
        case .cannotStartWriter(let message):
            return "无法开始录制：\(message)"
        case .recordingNotStarted:
            return "当前没有正在进行的录制。"
        }
    }
}

/// 本地截图 / H.264 视频录制。
///
/// 录制的是 App 已经显示出来的“换脸后”干净画面，不包含 SwiftUI 控件、
/// 原始画面 PiP 或输出窗口；文件由调用方指定目录。
final class MediaCapture {
    private let queue = DispatchQueue(label: "liveface.media-capture")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startHostTime: Double = 0
    private var lastPTS = CMTime.invalid
    private var outputURL: URL?
    private var videoSize = CGSize.zero
    private var recording = false
    private(set) var audioInputAdded = false
    private(set) var audioAppendSuccess = 0
    private(set) var audioAppendFailure = 0
    private(set) var audioAppendNotReady = 0
    private(set) var audioAppendBeforeStart = 0

    var isRecording: Bool { recording }
    var currentURL: URL? { outputURL }

    // MARK: - 截图

    static func saveScreenshot(_ image: CGImage, in directory: URL) throws -> URL {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MediaCaptureError.cannotCreateDirectory(directory.path)
        }

        let url = directory.appendingPathComponent(
            "LiveFace_\(timestamp()).png"
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw MediaCaptureError.cannotEncodeImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaCaptureError.cannotEncodeImage
        }
        return url
    }

    // MARK: - 录制

    func start(image: CGImage, in directory: URL, withAudio: Bool = false) throws -> URL {
        guard !recording else {
            return outputURL ?? directory.appendingPathComponent("LiveFace.mp4")
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MediaCaptureError.cannotCreateDirectory(directory.path)
        }

        // H.264 needs even dimensions.
        let width = max(2, image.width & ~1)
        let height = max(2, image.height & ~1)
        let url = directory.appendingPathComponent(
            "LiveFace_\(Self.timestamp()).mp4"
        )
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw MediaCaptureError.cannotStartWriter(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw MediaCaptureError.cannotStartWriter("视频输入不可用")
        }
        writer.add(input)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs
        )

        var audioInput: AVAssetWriterInput?
        if withAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
            let candidate = AVAssetWriterInput(
                mediaType: .audio, outputSettings: audioSettings
            )
            candidate.expectsMediaDataInRealTime = true
            if writer.canAdd(candidate) {
                writer.add(candidate)
                audioInput = candidate
                audioInputAdded = true
            }
        }

        let startHostTime = CACurrentMediaTime()
        guard writer.startWriting() else {
            throw MediaCaptureError.cannotStartWriter(
                writer.error?.localizedDescription ?? "startWriting 失败"
            )
        }
        writer.startSession(
            atSourceTime: CMTime(seconds: startHostTime, preferredTimescale: 600)
        )

        self.writer = writer
        self.input = input
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.outputURL = url
        self.videoSize = CGSize(width: width, height: height)
        self.startHostTime = startHostTime
        self.lastPTS = .invalid
        self.recording = true
        return url
    }

    /// hostTime 使用 CACurrentMediaTime()，与摄像头/显示时间同一时钟。
    func append(image: CGImage, hostTime: Double) {
        guard recording, let input, let adaptor else { return }
        guard input.isReadyForMoreMediaData else { return }
        guard let buffer = makePixelBuffer(from: image, adaptor: adaptor) else { return }

        guard hostTime >= startHostTime else { return }
        var pts = CMTime(seconds: hostTime, preferredTimescale: 600)
        if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 600))
        }
        if adaptor.append(buffer, withPresentationTime: pts) {
            lastPTS = pts
        }
    }

    /// 音频使用采集器原始 PTS（host clock），与视频共用同一个 session 起点。
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard recording, let audioInput else { return }
        guard audioInput.isReadyForMoreMediaData else {
            audioAppendNotReady += 1
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let start = CMTime(seconds: startHostTime, preferredTimescale: 600)
        if CMTimeCompare(pts, start) < 0 {
            audioAppendBeforeStart += 1
            return
        }
        if audioInput.append(sampleBuffer) {
            audioAppendSuccess += 1
        } else {
            audioAppendFailure += 1
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        guard recording, let writer, let input, let url = outputURL else {
            completion(.failure(MediaCaptureError.recordingNotStarted))
            return
        }
        recording = false
        input.markAsFinished()
        audioInput?.markAsFinished()
        self.writer = nil
        self.input = nil
        self.audioInput = nil
        self.adaptor = nil
        self.outputURL = nil

        writer.finishWriting {
            DispatchQueue.main.async {
                if writer.status == .completed {
                    completion(.success(url))
                } else {
                    completion(.failure(
                        writer.error ?? MediaCaptureError.cannotStartWriter("写入失败")
                    ))
                }
            }
        }
    }

    /// 退出 App 时尽力把文件收尾；最多等 2 秒。
    @discardableResult
    func finishSynchronously() -> URL? {
        guard recording, let writer, let input, let url = outputURL else { return nil }
        recording = false
        input.markAsFinished()
        audioInput?.markAsFinished()
        self.writer = nil
        self.input = nil
        self.audioInput = nil
        self.adaptor = nil
        self.outputURL = nil

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        _ = sem.wait(timeout: .now() + 2.0)
        return writer.status == .completed ? url : nil
    }

    // MARK: - 像素缓冲

    private func makePixelBuffer(
        from image: CGImage,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }

        // 视频缓冲与 CGBitmapContext 的绘制结果在这里方向一致；
        // 不再额外翻转，否则成片会上下颠倒。
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    // MARK: - 命名

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}
