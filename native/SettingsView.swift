import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case devices
    case video
    case recording
    case head
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: return "设备"
        case .video: return "画面"
        case .recording: return "录制"
        case .head: return "换头"
        case .status: return "状态与 OBS"
        }
    }

    var icon: String {
        switch self {
        case .devices: return "camera"
        case .video: return "slider.horizontal.3"
        case .recording: return "record.circle"
        case .head: return "person.crop.circle"
        case .status: return "waveform.path.ecg"
        }
    }
}

final class SettingsState: ObservableObject {
    @Published var tab: SettingsTab = .devices

    init() {
        if ProcessInfo.processInfo.arguments.contains("--settings-head") {
            tab = .head
        } else if ProcessInfo.processInfo.arguments.contains("--settings-recording") {
            tab = .recording
        } else if ProcessInfo.processInfo.arguments.contains("--settings-video") {
            tab = .video
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var backend: BackendClient
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @StateObject private var state = SettingsState()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("完成") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 168)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    state.tab = tab
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(state.tab == tab
                                      ? Color.accentColor.opacity(0.18)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.tab == tab ? .primary : .secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.white.opacity(0.025))
    }

    @ViewBuilder
    private var detail: some View {
        switch state.tab {
        case .devices:
            devicesView
        case .video:
            videoView
        case .recording:
            recordingView
        case .head:
            headView
        case .status:
            statusView
        }
    }

    // MARK: - 设备

    private var devicesView: some View {
        Form {
            Section("摄像头") {
                Picker("输入", selection: Binding(
                    get: { model.selectedCameraID },
                    set: { model.setCameraDevice($0) }
                )) {
                    Text("系统默认").tag("")
                    ForEach(model.cameraDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .disabled(model.isRunning)

                if model.isRunning {
                    Text("停止直播后可切换摄像头。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("麦克风") {
                Picker("输入", selection: Binding(
                    get: { model.selectedMicrophoneID },
                    set: { model.setMicrophoneDevice($0) }
                )) {
                    Text("系统默认").tag("")
                    ForEach(model.microphoneDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .disabled(model.isRecording)

                if model.isRecording {
                    Text("停止录制后可切换麦克风。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("刷新设备列表") { model.refreshDevices() }
                Text("外接设备未显示时，确认已连接，并允许 LiveFace 访问摄像头/麦克风。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 画面

    private var videoView: some View {
        Form {
            Section("采集") {
                Picker("分辨率", selection: Binding(
                    get: { model.captureResolution },
                    set: { model.setCaptureResolution($0) }
                )) {
                    ForEach(CaptureResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                .disabled(model.isRunning)

                LabeledContent("当前画面") {
                    Text("\(Int(model.displayedSize.width))×\(Int(model.displayedSize.height))")
                        .monospacedDigit()
                }

                if model.isRunning {
                    Text("停止直播后可切换采集分辨率。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("画质") {
                LabeledContent("发送画质") {
                    Text("\(Int(model.qualityPct))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.qualityPct, in: 50...95, step: 1)

                LabeledContent("输出画质") {
                    Text("\(model.serverJpegQuality)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.serverJpegQuality) },
                        set: { model.setServerJpegQuality(Int($0.rounded())) }
                    ),
                    in: 50...95, step: 1
                )

                LabeledContent("清晰度增强") {
                    Text("\(model.serverSharpen)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.serverSharpen) },
                        set: { model.setServerSharpen(Int($0.rounded())) }
                    ),
                    in: 0...100, step: 5
                )
            }

            Section("面部增强") {
                Toggle("GPEN-BFR-256 面部增强", isOn: Binding(
                    get: { model.faceEnhance },
                    set: { model.setFaceEnhance($0) }
                ))

                if model.faceEnhance {
                    if model.faceEnhanceReady {
                        Text("增强模型已就绪")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if let error = model.faceEnhanceError, !error.isEmpty {
                        Text("增强模型加载失败：\(error)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else {
                        Text("增强模型准备中（首次下载约 75MB）")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text("换脸模型输出为 128×128；面部增强会显著提升清晰度，但会增加延迟、发热和内存占用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("画质预设") {
                HStack {
                    Button("流畅优先") { model.applyQualityPreset(.smooth) }
                    Button("均衡") { model.applyQualityPreset(.balanced) }
                    Button("清晰优先") { model.applyQualityPreset(.clear) }
                }
                Text("清晰优先 = 1080p + 高画质 + 面部增强；首次启用需要下载并编译 GPEN 模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("更高分辨率/画质会增加延迟和发热；4K 对这台机器可能明显降帧。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 录制

    private var recordingView: some View {
        Form {
            Section("保存位置") {
                HStack {
                    Text(model.captureDirectoryDisplay)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…") { model.chooseCaptureDirectory() }
                    Button("打开") { model.openCaptureDirectory() }
                }
            }

            Section("录制选项") {
                Picker("倒计时", selection: $model.recordCountdownSeconds) {
                    Text("关闭").tag(0)
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                }

                Picker("画质", selection: $model.videoBitrateMbps) {
                    Text("4 Mbps").tag(4)
                    Text("8 Mbps").tag(8)
                    Text("12 Mbps").tag(12)
                    Text("16 Mbps").tag(16)
                    Text("32 Mbps").tag(32)
                }
                .disabled(model.isRecording)

                Picker("最长录制", selection: $model.maxRecordingMinutes) {
                    Text("不限").tag(0)
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("30 分钟").tag(30)
                }
                .disabled(model.isRecording)

                Toggle("录制麦克风", isOn: $model.recordMicrophone)
                    .disabled(model.isRecording)
            }

            Section("快捷操作") {
                HStack {
                    Button("截图") { model.captureScreenshot() }
                    if model.isRecording {
                        Button(model.isRecordingPaused ? "继续录制" : "暂停录制") {
                            model.toggleRecordingPause()
                        }
                    }
                    Button(model.isRecording ? "停止录制" : "开始录制") {
                        model.toggleRecording()
                    }
                }
            }

            Section("最近文件") {
                if model.recentCaptures.isEmpty {
                    Text("还没有截图或录制文件。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.recentCaptures.prefix(5))) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isVideo ? "film" : "photo")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(item.dateText) · \(item.sizeText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.openCapture(item)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderless)
                            .help("打开")

                            Button {
                                model.revealCapture(item)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("在 Finder 中显示")

                            Button {
                                model.deleteCapture(item)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除")
                        }
                    }
                    Button("刷新列表") { model.refreshRecentCaptures() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 换头

    private var headView: some View {
        Form {
            Section("模式") {
                Picker("模式", selection: Binding(
                    get: { model.headSwap },
                    set: { model.setHeadSwap($0) }
                )) {
                    Text("换脸（仅面部）").tag(false)
                    Text("换头（实验）").tag(true)
                }
                Text("换头会在换脸基础上叠加源照片的发型、耳朵和头部轮廓；保留目标表情。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("预设") {
                Menu("应用预设") {
                    Button("自然（弱）") { model.applyHeadPreset(.natural) }
                    Button("均衡（默认）") { model.applyHeadPreset(.balanced) }
                    Button("明显（强）") { model.applyHeadPreset(.strong) }
                }
            }

            Section("微调") {
                LabeledContent("换头强度") {
                    Text("\(model.headStrength)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.headStrength) },
                        set: { model.setHeadStrength(Int($0.rounded())) }
                    ),
                    in: 0...100, step: 5
                )

                LabeledContent("头部缩放") {
                    Text("\(model.headScale)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.headScale) },
                        set: { model.setHeadScale(Int($0.rounded())) }
                    ),
                    in: 85...115, step: 1
                )

                LabeledContent("上下微调") {
                    Text(offsetText(model.headOffsetY))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.headOffsetY) },
                        set: { model.setHeadOffsetY(Int($0.rounded())) }
                    ),
                    in: -20...20, step: 1
                )

                LabeledContent("左右微调") {
                    Text(offsetText(model.headOffsetX))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.headOffsetX) },
                        set: { model.setHeadOffsetX(Int($0.rounded())) }
                    ),
                    in: -20...20, step: 1
                )

                Text("强度 0 = 仅换脸；缩放和上下/左右微调可减少接缝。建议正脸、半身照。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func offsetText(_ value: Int) -> String {
        value == 0 ? "0%" : (value > 0 ? "+\(value)%" : "\(value)%")
    }

    // MARK: - 状态 / OBS

    private var statusView: some View {
        Form {
            Section("运行状态") {
                LabeledContent("加速") {
                    Text(backend.state?.coreml == true ? "CoreML / ANE" : "CPU")
                }
                LabeledContent("服务端 P50") {
                    Text(backend.state?.stats?.server_p50_ms.map { "\(Int($0)) ms" } ?? "–")
                }
                LabeledContent("检测 / 换脸 / 编码") {
                    Text(breakdownText)
                }
                LabeledContent("模型预热") {
                    Text(warmupText)
                }
                LabeledContent("闲置自动退出") {
                    Text(idleText)
                }
            }

            Section("输出窗口") {
                Toggle("输出窗口置顶", isOn: $model.outputAlwaysOnTop)
                Text("置顶后 OBS 采集时也不会被其他窗口盖住；窗口位置和大小会自动记住。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("快捷键") {
                shortcut("空格", "开始 / 停止直播")
                shortcut("1–9", "切换照片")
                shortcut("⌘S", "截图")
                shortcut("⌘R", "开始 / 停止录制")
                shortcut("⌘P", "暂停 / 继续录制")
                shortcut("⌘⇧O", "打开输出窗口")
                shortcut("⌘,", "打开设置")
                shortcut("F / Esc", "输出窗口全屏 / 关闭")
            }

            Section("维护") {
                Button("打开日志目录") { model.openLogs() }
                Button("重置窗口位置") { model.resetWindowFrames() }
                Text("重置后下次启动恢复默认窗口位置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OBS 采集") {
                Text("1. 点「输出窗口」，把弹出的窗口拖到合适大小。")
                Text("2. OBS 添加「窗口采集」，选择「实时换脸输出」。")
                Text("3. 麦克风「同步偏移」= 侧栏固定延迟。")
                Text("输出窗口内按 F 或双击全屏，Esc 关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        HStack {
            Text(action)
            Spacer()
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var breakdownText: String {
        guard let stats = backend.state?.stats else { return "–" }
        var parts: [String] = []
        if let detect = stats.avg_detect_ms { parts.append("检 \(Int(detect))") }
        if let swap = stats.avg_swap_ms { parts.append("换 \(Int(swap))") }
        if let encode = stats.avg_encode_ms { parts.append("编 \(Int(encode))") }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ") + " ms"
    }

    private var warmupText: String {
        guard let warmup = backend.state?.warmup else { return "–" }
        if warmup.swap_warming == true { return "编译中…" }
        if let swap = warmup.swap_ms {
            let detect = warmup.detect_ms.map { Int($0) } ?? 0
            return "检测 \(detect) / 换脸 \(Int(swap)) ms"
        }
        return "待上传照片"
    }

    private var idleText: String {
        guard let seconds = backend.state?.idle_remaining_s else { return "–" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

extension Notification.Name {
    static let liveFaceOpenSettings = Notification.Name("LiveFaceOpenSettings")
}
