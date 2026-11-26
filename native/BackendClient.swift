import Foundation
import AppKit

extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

/// 与本地 Python 换脸服务通信；必要时在后台静默启动它。
final class BackendClient: ObservableObject {
    static let port = 8787
    static let baseURL = URL(string: "http://127.0.0.1:8787")!

    @Published var state: ServerState?
    @Published var connected = false
    @Published var startupMessage = "正在启动换脸服务…"
    @Published var lastError: String?

    let projectPath: String

    private let session: URLSession
    private let sessionID = UUID().uuidString
    private var pollTimer: Timer?
    private var backendProcess: Process?
    private var startedByUs = false
    private var starting = false
    private var launchScheduled = false
    private var logHandle: FileHandle?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg)
        projectPath = BackendClient.resolveProjectPath()
    }

    // MARK: - 生命周期

    func start() {
        print("[backend] start project=\(projectPath)")
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()

        // 给已有服务 1.2 秒响应时间；没有响应才启动新的
        if !launchScheduled {
            launchScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, !self.connected else { return }
                self.ensureBackend()
            }
        }
    }

    func ensureBackend() {
        if connected || starting { return }
        if let p = backendProcess, p.isRunning { return }
        starting = true

        let fm = FileManager.default
        let python = projectPath + "/.venv/bin/python"
        guard fm.isExecutableFile(atPath: python),
              fm.fileExists(atPath: projectPath + "/web_server.py") else {
            starting = false
            lastError = "找不到项目或虚拟环境：\n\(projectPath)"
            return
        }

        let logs = projectPath + "/logs"
        try? fm.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let logPath = logs + "/native-app.log"
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            logHandle = handle
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["web_server.py", "--port", String(BackendClient.port)]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.environment = ProcessInfo.processInfo.environment
        if let logHandle {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.backendProcess = nil
                self?.startedByUs = false
            }
        }

        do {
            try process.run()
            backendProcess = process
            startedByUs = true
            startupMessage = "正在加载换脸模型…"
        } catch {
            lastError = "启动服务失败：\(error.localizedDescription)"
        }
        starting = false
    }

    func stopIfStarted() {
        guard startedByUs, let process = backendProcess else { return }
        if process.isRunning { process.terminate() }
        backendProcess = nil
        startedByUs = false
    }

    // MARK: - 状态

    func refresh() {
        var request = URLRequest(url: BackendClient.baseURL.appendingPathComponent("api/state"))
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            if let data,
               let decoded = try? JSONDecoder().decode(ServerState.self, from: data) {
                DispatchQueue.main.async {
                    self.state = decoded
                    self.connected = true
                    self.startupMessage = decoded.message
                    print("[backend] state=\(decoded.status) photos=\(decoded.photos.count)")
                }
            } else {
                DispatchQueue.main.async {
                    print("[backend] state fetch failed")
                    self.connected = false
                    if self.state?.status == "ready" {
                        self.state = nil
                    }
                }
            }
        }.resume()
    }

    // MARK: - 帧

    func sendFrame(jpeg: Data, capture: Double, completion: @escaping (FrameResponse) -> Void) {
        var timestamp = capture.bitPattern.littleEndian
        var packet = Data()
        withUnsafeBytes(of: &timestamp) { packet.append(contentsOf: $0) }
        packet.append(jpeg)

        var comps = URLComponents(
            url: BackendClient.baseURL.appendingPathComponent("api/frame"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "s", value: sessionID)]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.httpBody = packet
        request.timeoutInterval = 10
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        session.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            func header(_ name: String) -> Double {
                Double((http?.value(forHTTPHeaderField: name)) ?? "") ?? 0
            }
            let result = FrameResponse(
                status: status,
                data: status == 200 ? data : nil,
                processMs: header("X-Process-Ms"),
                detectMs: header("X-Detect-Ms"),
                swapMs: header("X-Swap-Ms"),
                encodeMs: header("X-Encode-Ms"),
                swapped: http?.value(forHTTPHeaderField: "X-Swapped") == "1",
                detected: http?.value(forHTTPHeaderField: "X-Detected") == "1"
            )
            completion(result)
        }.resume()
    }

    // MARK: - 照片 / 配置

    func upload(urls: [URL], completion: @escaping (Result<Int, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let boundary = "----LiveFaceBoundary\(UUID().uuidString)"
            var body = Data()
            var count = 0

            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
                let name = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
                body.appendString("--\(boundary)\r\n")
                body.appendString("Content-Disposition: form-data; name=\"photos\"; filename=\"\(name)\"\r\n")
                body.appendString("Content-Type: image/jpeg\r\n\r\n")
                body.append(data)
                body.appendString("\r\n")
                count += 1
            }

            guard count > 0 else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "LiveFace", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "没有可读取的图片"]
                    )))
                }
                return
            }
            body.appendString("--\(boundary)--\r\n")

            var request = URLRequest(url: BackendClient.baseURL.appendingPathComponent("api/upload"))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 60

            self.session.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200 {
                        self.refresh()
                        completion(.success(count))
                    } else {
                        var message = "上传失败（HTTP \(code)）"
                        if let data,
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let serverError = obj["error"] as? String {
                            message = serverError
                        }
                        completion(.failure(NSError(
                            domain: "LiveFace", code: code,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )))
                    }
                }
            }.resume()
        }
    }

    func select(_ id: String) {
        postJSON("api/select", ["id": id])
    }

    func deletePhoto(_ id: String) {
        postJSON("api/delete", ["id": id])
    }

    func setDetectInterval(_ value: Int) {
        postJSON("api/config", ["detect_interval": value])
    }

    func setSwapCount(_ value: Int) {
        postJSON("api/config", ["swap_count": value])
    }

    func setHeadSwap(_ value: Bool) {
        postJSON("api/config", ["head_swap": value])
    }

    func selectTarget(x: Double, y: Double, completion: @escaping (Bool, String?) -> Void) {
        var comps = URLComponents(
            url: BackendClient.baseURL.appendingPathComponent("api/target"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "s", value: sessionID)]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["x": x, "y": y])
        request.timeoutInterval = 5
        session.dataTask(with: request) { data, _, _ in
            var ok = false
            var message: String?
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = obj["ok"] as? Bool ?? false
                message = obj["error"] as? String
            }
            DispatchQueue.main.async {
                completion(ok, message)
            }
        }.resume()
    }

    func resetTarget(completion: ((Bool) -> Void)? = nil) {
        var comps = URLComponents(
            url: BackendClient.baseURL.appendingPathComponent("api/target/reset"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "s", value: sessionID)]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        session.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.async { completion?(true) }
        }.resume()
    }

    private func postJSON(_ path: String, _ object: [String: Any]) {
        var request = URLRequest(url: BackendClient.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
        request.timeoutInterval = 5
        session.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }.resume()
    }

    // MARK: - 路径

    static func resolveProjectPath() -> String {
        let fm = FileManager.default
        if let url = Bundle.main.url(forResource: "ProjectPath", withExtension: "txt"),
           let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           fm.fileExists(atPath: value + "/web_server.py") {
            return value
        }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.appendingPathComponent("web_server.py").path) {
            return parent.path
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("backend")
            if fm.fileExists(atPath: bundled.appendingPathComponent("web_server.py").path) {
                return bundled.path
            }
        }
        return Bundle.main.bundleURL.deletingLastPathComponent().path
    }
}
