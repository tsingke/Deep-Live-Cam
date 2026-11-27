import Foundation
import AppKit
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreGraphics
import QuartzCore

// Synthetic screenshot + MP4 smoke test. No camera, microphone or user data.
let dir = URL(fileURLWithPath: "/tmp/LiveFaceRecordingSmoke", isDirectory: true)
try? FileManager.default.removeItem(at: dir)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let width = 640
let height = 360

func makeImage(_ index: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    ctx.setFillColor(CGColor(red: 0.15, green: 0.25, blue: 0.85, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1))
    ctx.fill(CGRect(x: CGFloat(30 + (index * 9) % 500), y: 140, width: 60, height: 60))
    return ctx.makeImage()!
}

func makeAudio(_ pts: CMTime) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
        mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format
    ) == noErr, let format else { return nil }

    let frames = 1536
    let byteCount = frames * 2
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
        flags: 0, blockBufferOut: &block
    ) == noErr, let block else { return nil }
    _ = CMBlockBufferAssureBlockMemory(block)

    var ptr: UnsafeMutablePointer<Int8>?
    var lengthAtOffset = 0
    var totalLength = 0
    guard CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength, dataPointerOut: &ptr
    ) == noErr, let ptr else { return nil }
    ptr.withMemoryRebound(to: Int16.self, capacity: frames) { p in
        for i in 0..<frames {
            let phase = Double(i % 48) / 48.0 * 2.0 * Double.pi
            p[i] = Int16(sin(phase) * 6000.0)
        }
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: Int64(frames), timescale: 48_000),
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
        sampleCount: frames, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
    ) == noErr else { return nil }
    return sampleBuffer
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

let image = makeImage(0)
do {
    let png = try MediaCapture.saveScreenshot(image, in: dir)
    guard FileManager.default.fileExists(atPath: png.path) else { fail("screenshot missing") }
} catch {
    fail("screenshot: \(error)")
}

let recorder = MediaCapture()
do {
    let url = try recorder.start(image: image, in: dir, withAudio: true, videoBitrate: 8_000_000)
    func appendOne(_ i: Int) {
        usleep(33_000)
        let now = CACurrentMediaTime()
        recorder.append(image: makeImage(i), hostTime: now)
        if let audio = makeAudio(CMTime(seconds: now, preferredTimescale: 48_000)) {
            recorder.appendAudio(audio)
        }
    }
    for i in 0..<10 { appendOne(i) }
    recorder.pause(at: CACurrentMediaTime())
    for i in 10..<15 { appendOne(i) }
    usleep(300_000)
    recorder.resume(at: CACurrentMediaTime())
    for i in 15..<35 { appendOne(i) }

    var finished = false
    recorder.finish { result in
        if case .failure(let error) = result { fail("finish: \(error)") }
        finished = true
    }
    let deadline = Date().addingTimeInterval(12)
    while !finished && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard finished else { fail("finish timeout") }
    guard FileManager.default.fileExists(atPath: url.path) else { fail("mp4 missing") }

    let asset = AVAsset(url: url)
    let videoTracks = asset.tracks(withMediaType: .video)
    let audioTracks = asset.tracks(withMediaType: .audio)
    guard videoTracks.count == 1 else { fail("expected 1 video track, got \(videoTracks.count)") }
    guard audioTracks.count == 1 else { fail("expected 1 audio track, got \(audioTracks.count)") }
    let duration = CMTimeGetSeconds(asset.duration)
    guard duration > 0.8 && duration < 1.55 else {
        fail("unexpected duration \(duration) (pause should be removed)")
    }
    print("PASS recording smoke: video=\(videoTracks.count) audio=\(audioTracks.count) duration=\(duration)")
} catch {
    fail("recording: \(error)")
}
