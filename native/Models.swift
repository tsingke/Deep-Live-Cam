import Foundation

struct PhotoInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    let thumb: String
}

struct ServerSettings: Codable {
    var detect_interval: Int
    var jpeg_quality: Int
    var swap_count: Int
    var head_swap: Bool?
}

struct WarmupInfo: Codable {
    let detect_ms: Double?
    let swap_ms: Double?
    let swap_warming: Bool?
}

struct ServerStats: Codable {
    let frames: Int?
    let dropped: Int?
    let server_p50_ms: Double?
    let server_p95_ms: Double?
    let avg_decode_ms: Double?
    let avg_detect_ms: Double?
    let avg_swap_ms: Double?
    let avg_encode_ms: Double?
    let last_total_ms: Double?
    let avg_fps_30s: Double?
}

struct ServerState: Codable {
    let status: String
    let message: String
    let ready: Bool
    let error: String?
    let coreml: Bool
    let providers: [String]?
    let photos: [PhotoInfo]
    let active: String?
    let settings: ServerSettings
    let warmup: WarmupInfo
    let stats: ServerStats?
    let busy: Int?
    let queue: Int?
    let uptime_s: Int?
    let idle_timeout_s: Int?
    let idle_remaining_s: Int?
    let version: String?
}

struct FrameResponse {
    let status: Int
    let data: Data?
    let processMs: Double
    let detectMs: Double
    let swapMs: Double
    let encodeMs: Double
    let swapped: Bool
    let detected: Bool
}
