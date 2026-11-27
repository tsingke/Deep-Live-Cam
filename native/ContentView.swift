import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

// MARK: - 主题

enum Theme {
    static let accent = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let card = Color.white.opacity(0.045)
    static let stroke = Color.white.opacity(0.075)
    static let danger = Color(red: 1.0, green: 0.33, blue: 0.42)
}

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

// MARK: - 局部 UI 状态（避开 @State 宏，命令行工具链也能编译）

final class UIState: ObservableObject {
    @Published var importing = false
    @Published var dropTargeted = false
    @Published var showStats = false
    @Published var showOBS = false
    @Published var hoveredPhotoID: String?
    @Published var uploadHover = false
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject private var backend: BackendClient
    @EnvironmentObject private var model: AppModel
    @StateObject private var ui = UIState()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(ui: ui)
                .frame(width: 344)
            PreviewPane()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $ui.importing,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.upload(urls)
            case .failure(let error):
                model.alertMessage = error.localizedDescription
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $ui.dropTargeted) { providers in
            model.handleDrop(providers)
        }
        .overlay {
            if ui.dropTargeted {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Theme.cyan)
                        Text("松手即可上传人像照片")
                            .font(.system(size: 16, weight: .semibold))
                        Text("支持 JPG / PNG / WEBP，可一次拖入多张")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 42)
                    .padding(.vertical, 32)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    )
                }
            }
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            if model.cameraPermissionIssue {
                Button("打开摄像头设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                    model.alertMessage = nil
                }
            }
            Button("好的", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let message = model.transientMessage {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .padding(.bottom, 22)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.transientMessage)
        .onAppear {
            print("[ui] onAppear")
            model.startServices()
        }
    }
}

// MARK: - 侧栏

private struct SidebarView: View {
    @EnvironmentObject private var backend: BackendClient
    @EnvironmentObject private var model: AppModel
    @ObservedObject var ui: UIState

    private var photos: [PhotoInfo] { backend.state?.photos ?? [] }
    private var activeID: String? { backend.state?.active }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    photosSection
                    controlsSection
                    devicesSection
                    statsSection
                    obsSection
                    captureSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 26)
                .padding(.bottom, 16)
            }

            Divider().overlay(Color.white.opacity(0.06))
            bottomBar.padding(14)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.085, green: 0.095, blue: 0.12),
                    Color(red: 0.055, green: 0.062, blue: 0.078)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconBadge(size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("实时换脸")
                    .font(.system(size: 20, weight: .bold))
                Text("LIVE FACE STUDIO")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.7)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            StatusPill()
        }
        .padding(.bottom, 2)
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("人物照片")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(photos.count) 张")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if photos.isEmpty {
                EmptyUploadTile(ui: ui) { ui.importing = true }
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(photos.indices, id: \.self) { index in
                        PhotoTile(
                            photo: photos[index],
                            index: index,
                            isActive: photos[index].id == activeID,
                            ui: ui
                        )
                    }
                    UploadTile(ui: ui) { ui.importing = true }
                }
            }

            Text(photos.isEmpty
                 ? "支持 JPG / PNG / WEBP，可一次选择多张；也可以直接拖进窗口。"
                 : "点击缩略图或按 1–9 切换；也可把图片直接拖进窗口。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("同步与画质")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(model.delayMs == 0 ? "低延迟" : "同步 +\(Int(model.delayMs)) ms")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(model.delayMs == 0 ? Color.secondary : Theme.cyan)
            }

            VStack(spacing: 7) {
                HStack {
                    Text("固定延迟").font(.system(size: 12))
                    Spacer()
                    Text("\(Int(model.delayMs)) ms")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.cyan)
                }
                Slider(value: $model.delayMs, in: 0...1000, step: 10)
                    .tint(Theme.accent)
            }

            Text("0 = 最低延迟；音画同步时设为 300，OBS 麦克风偏移同值。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 7) {
                HStack {
                    Text("发送画质").font(.system(size: 12))
                    Spacer()
                    Text("\(Int(model.qualityPct))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.cyan)
                }
                Slider(value: $model.qualityPct, in: 50...90, step: 1)
                    .tint(Theme.accent)
            }

            HStack {
                Text("人脸检测间隔").font(.system(size: 12))
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { model.detectInterval },
                        set: { model.setDetectInterval($0) }
                    )
                ) {
                    Text("每帧").tag(1)
                    Text("每 2 帧").tag(2)
                    Text("每 3 帧").tag(3)
                    Text("每 4 帧").tag(4)
                    Text("每 6 帧").tag(6)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 104)
            }

            HStack {
                Text("换脸人数").font(.system(size: 12))
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { model.swapCount },
                        set: { model.setSwapCount($0) }
                    )
                ) {
                    Text("1 人（主角）").tag(1)
                    Text("2 人").tag(2)
                    Text("3 人").tag(3)
                    Text("全部").tag(0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 124)
            }

            HStack {
                Text("模式").font(.system(size: 12))
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { model.headSwap },
                        set: { model.setHeadSwap($0) }
                    )
                ) {
                    Text("换脸（仅面部）").tag(false)
                    Text("换头（实验）").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 124)
            }

            Text("换头会叠加源照片的发型/头部轮廓，保留目标表情；建议正脸、半身照。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.headSwap {
                VStack(spacing: 7) {
                    HStack {
                        Text("预设").font(.system(size: 12))
                        Spacer()
                        Menu("应用预设") {
                            Button("自然（弱）") { model.applyHeadPreset(.natural) }
                            Button("均衡（默认）") { model.applyHeadPreset(.balanced) }
                            Button("明显（强）") { model.applyHeadPreset(.strong) }
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 124)
                    }

                    HStack {
                        Text("换头强度").font(.system(size: 12))
                        Spacer()
                        Text("\(model.headStrength)%")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.cyan)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.headStrength) },
                            set: { model.setHeadStrength(Int($0.rounded())) }
                        ),
                        in: 0...100, step: 5
                    )
                    .tint(Theme.accent)

                    HStack {
                        Text("头部缩放").font(.system(size: 12))
                        Spacer()
                        Text("\(model.headScale)%")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.cyan)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.headScale) },
                            set: { model.setHeadScale(Int($0.rounded())) }
                        ),
                        in: 85...115, step: 1
                    )
                    .tint(Theme.accent)

                    HStack {
                        Text("上下微调").font(.system(size: 12))
                        Spacer()
                        Text(model.headOffsetY == 0
                             ? "0%"
                             : (model.headOffsetY > 0
                                ? "+\(model.headOffsetY)%"
                                : "\(model.headOffsetY)%"))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.cyan)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.headOffsetY) },
                            set: { model.setHeadOffsetY(Int($0.rounded())) }
                        ),
                        in: -20...20, step: 1
                    )
                    .tint(Theme.accent)

                    HStack {
                        Text("左右微调").font(.system(size: 12))
                        Spacer()
                        Text(model.headOffsetX == 0
                             ? "0%"
                             : (model.headOffsetX > 0
                                ? "+\(model.headOffsetX)%"
                                : "\(model.headOffsetX)%"))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.cyan)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.headOffsetX) },
                            set: { model.setHeadOffsetX(Int($0.rounded())) }
                        ),
                        in: -20...20, step: 1
                    )
                    .tint(Theme.accent)
                }
                .padding(.top, 2)

                Text("强度 0 = 仅换脸；缩放/上下微调可减少接缝。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("点击画面中的人脸可锁定主角")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("自动选择") {
                    model.resetTarget()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.accent)
            }
        }
        .cardStyle()
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("设备")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("刷新") { model.refreshDevices() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }

            HStack {
                Text("摄像头").font(.system(size: 12))
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { model.selectedCameraID },
                        set: { model.setCameraDevice($0) }
                    )
                ) {
                    Text("系统默认").tag("")
                    ForEach(model.cameraDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 184)
                .disabled(model.isRunning)
            }

            HStack {
                Text("麦克风").font(.system(size: 12))
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { model.selectedMicrophoneID },
                        set: { model.setMicrophoneDevice($0) }
                    )
                ) {
                    Text("系统默认").tag("")
                    ForEach(model.microphoneDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 184)
                .disabled(model.isRecording)
            }

            if model.isRunning || model.isRecording {
                Text(model.isRunning
                     ? "停止直播后可切换摄像头；停止录制后可切换麦克风。"
                     : "停止录制后可切换麦克风。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("可选外接摄像头/麦克风；未选择时使用系统默认。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("截图与录制")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.isRecording {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.danger).frame(width: 6, height: 6)
                        Text("REC \(model.recordTimeText)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.danger)
                    }
                } else {
                    Text("本地保存")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("保存到")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("选择…") {
                    model.chooseCaptureDirectory()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.accent)
            }

            Text(model.captureDirectoryDisplay)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.captureDirectory.path)

            HStack {
                Text("录制倒计时").font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.recordCountdownSeconds) {
                    Text("关闭").tag(0)
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 96)
            }

            HStack {
                Text("录制画质").font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.videoBitrateMbps) {
                    Text("4 Mbps").tag(4)
                    Text("8 Mbps").tag(8)
                    Text("12 Mbps").tag(12)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 96)
                .disabled(model.isRecording)
            }

            HStack {
                Text("最长录制").font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.maxRecordingMinutes) {
                    Text("不限").tag(0)
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("30 分钟").tag(30)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 96)
                .disabled(model.isRecording)
            }

            HStack {
                Text("录制麦克风").font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $model.recordMicrophone)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(model.isRecording)
            }

            HStack(spacing: 8) {
                Button {
                    model.captureScreenshot()
                } label: {
                    Label("截图", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    model.toggleRecording()
                } label: {
                    Label(
                        model.recordCountdown != nil
                        ? "取消"
                        : (model.isRecording ? "停止" : "录制"),
                        systemImage: model.recordCountdown != nil
                        ? "xmark"
                        : (model.isRecording ? "stop.fill" : "record.circle")
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? Theme.danger : Theme.accent)
            }
            .controlSize(.regular)

            HStack {
                Button("打开目录") {
                    model.openCaptureDirectory()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.accent)

                Spacer()

                Text(
                    model.isRecording
                    ? (model.recordingWithAudio ? "H.264 · 麦克风" : "H.264 · 无音频")
                    : "PNG · MP4（H.264 + 麦克风）"
                )
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            }

            Text("录制换脸后的干净画面，不含界面控件；首次录制会请求麦克风，拒绝则只录画面。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.recentCaptures.isEmpty {
                Divider()
                    .overlay(Color.white.opacity(0.07))

                HStack {
                    Text("最近文件")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { model.refreshRecentCaptures() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }

                ForEach(Array(model.recentCaptures.prefix(3))) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isVideo ? "film" : "photo")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(item.dateText) · \(item.sizeText)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 4)

                        Button {
                            model.openCapture(item)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                        .help("打开")

                        Button {
                            model.revealCapture(item)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中显示")

                        Button {
                            model.deleteCapture(item)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("删除")
                    }
                }
            }
        }
        .cardStyle()
    }

    private var statsSection: some View {
        DisclosureGroup(isExpanded: $ui.showStats) {
            VStack(spacing: 6) {
                statRow("加速", backend.state?.coreml == true ? "CoreML / ANE" : "CPU")
                statRow("服务端 P50", backend.state?.stats?.server_p50_ms.map { "\(Int($0)) ms" } ?? "–")
                statRow("检测 / 换脸 / 编码", breakdownText)
                statRow("模型预热", warmupText)
                statRow("闲置自动退出", idleText)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("运行状态")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(statusSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var statusSummary: String {
        guard let state = backend.state else {
            return backend.connected ? "连接中" : "启动中"
        }
        let accel = state.coreml ? "CoreML" : "CPU"
        if let p50 = state.stats?.server_p50_ms {
            return "\(accel) · P50 \(Int(p50)) ms"
        }
        return accel
    }

    private var obsSection: some View {
        DisclosureGroup(isExpanded: $ui.showOBS) {
            VStack(alignment: .leading, spacing: 7) {
                Text("1. 点「输出窗口」，把弹出的窗口拖到合适大小。")
                Text("2. OBS 添加「窗口采集」→ 选择「实时换脸输出」。")
                Text("3. 麦克风「同步偏移」= 上方固定延迟。")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        } label: {
            Text("OBS 采集")
                .font(.system(size: 12, weight: .semibold))
        }
        .cardStyle()
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Button {
                model.toggleCamera()
            } label: {
                Label(
                    model.isRunning ? "停止直播" : "开始直播",
                    systemImage: model.isRunning ? "stop.fill" : "video.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.isRunning ? Theme.danger : Theme.accent)

            Button {
                model.showOutputWindow()
            } label: {
                Label("输出窗口", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
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

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }
}

// MARK: - 预览区

private struct PreviewPane: View {
    @EnvironmentObject private var backend: BackendClient
    @EnvironmentObject private var model: AppModel

    private var photos: [PhotoInfo] { backend.state?.photos ?? [] }
    private var activePhotoName: String {
        guard let active = backend.state?.active,
              let photo = photos.first(where: { $0.id == active }) else { return "未选择" }
        return photo.name
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

            preview
                .padding(.horizontal, 20)

            footer
                .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.isRunning ? "LIVE" : "待机")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(model.isRunning ? .white : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        model.isRunning
                            ? AnyShapeStyle(LinearGradient(
                                colors: [Color(red: 1.0, green: 0.33, blue: 0.42), Color(red: 0.86, green: 0.11, blue: 0.28)],
                                startPoint: .top, endPoint: .bottom
                            ))
                            : AnyShapeStyle(Color.white.opacity(0.06))
                    )
                )

            Text(model.isRunning ? "1280×720 · 实时换脸中" : "摄像头未开启")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if model.isRecording {
                HStack(spacing: 5) {
                    Circle().fill(Theme.danger).frame(width: 6, height: 6)
                    Text("REC \(model.recordTimeText)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.danger)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.danger.opacity(0.12)))
                .overlay(Capsule().stroke(Theme.danger.opacity(0.35), lineWidth: 1))

                MicLevelIndicator(level: model.micLevel, active: model.recordingWithAudio)
            }

            Spacer()

            Button {
                model.captureScreenshot()
            } label: {
                Label("截图", systemImage: "camera")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("保存当前换脸画面为 PNG（⌘S）")

            Button {
                model.toggleRecording()
            } label: {
                Label(
                    model.recordCountdown != nil
                    ? "取消"
                    : (model.isRecording ? "停止" : "录制"),
                    systemImage: model.recordCountdown != nil
                    ? "xmark"
                    : (model.isRecording ? "stop.fill" : "record.circle")
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(model.isRecording ? Theme.danger : Theme.accent)
            .help(model.isRecording ? "停止并保存 H.264 视频（⌘R）" : "录制换脸后的画面与麦克风（⌘R）")

            Button {
                model.chooseCaptureDirectory()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("选择截图 / 录制的保存目录")

            Divider()
                .frame(height: 18)
                .overlay(Color.white.opacity(0.12))

            MetricChip(label: "FPS", value: String(format: "%.1f", model.fps))
            MetricChip(label: "延迟", value: model.latencyMs.map { "\(Int($0)) ms" } ?? "–")
            MetricChip(label: "丢帧", value: "\(model.dropped + model.skipped)")
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black)

            if let image = model.displayedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            if !model.isRunning {
                idleOverlay
            }

            if let countdown = model.recordCountdown {
                countdownOverlay(countdown)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay {
            if model.isRunning, model.recordCountdown == nil, let image = model.displayedImage {
                GeometryReader { geo in
                    let iw = max(CGFloat(image.width), 1)
                    let ih = max(CGFloat(image.height), 1)
                    let scale = min(geo.size.width / iw, geo.size.height / ih)
                    let contentW = iw * scale
                    let contentH = ih * scale
                    let offsetX = (geo.size.width - contentW) / 2
                    let offsetY = (geo.size.height - contentH) / 2

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture().onEnded { value in
                                let x = (value.location.x - offsetX) / max(contentW, 1)
                                let y = (value.location.y - offsetY) / max(contentH, 1)
                                guard x >= 0, x <= 1, y >= 0, y <= 1 else { return }
                                model.selectTarget(x: Double(x), y: Double(y))
                            }
                        )
                        .onHover { inside in
                            if inside { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                        }
                }
                .help("点击画面中的人脸，锁定换脸主角")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.isRunning, model.previewImage != nil {
                rawPreview
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isRunning {
                Text("点击人脸锁定 · 1–9 换人 · 空格停止")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(16)
            }
        }
        .frame(minHeight: 420)
        .animation(.easeInOut(duration: 0.2), value: model.isRunning)
    }

    private func countdownOverlay(_ countdown: Int) -> some View {
        ZStack {
            Color.black.opacity(0.66)

            VStack(spacing: 12) {
                Text("\(countdown)")
                    .font(.system(size: 78, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("秒后开始录制")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("取消") {
                    model.cancelRecordCountdown()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var idleOverlay: some View {
        ZStack {
            Color.black.opacity(0.58)

            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Theme.accent, Theme.cyan],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 64, height: 64)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Theme.accent.opacity(0.45), radius: 18, y: 8)

                Text(idleTitle)
                    .font(.system(size: 24, weight: .semibold))

                Text(idleSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                if model.isReady {
                    Button("开始直播") {
                        model.toggleCamera()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .padding(.top, 4)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
            .padding(30)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var rawPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("原始画面")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
            Group {
                if let preview = model.previewImage {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.black
                }
            }
            .frame(width: 176, height: 99)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
    }

    private var footer: some View {
        HStack(spacing: 22) {
            footerItem("拍摄→显示", model.displayDelayMs.map { "\(Int($0)) ms" } ?? "–")
            footerItem("固定延迟", "\(Int(model.delayMs)) ms")
            footerItem("当前人物", activePhotoName)
            Spacer()
            Text("空格 开始/停止 · 1–9 换人 · ⌘S 截图 · ⌘R 录制")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func footerItem(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private var idleTitle: String {
        guard let state = backend.state else {
            return backend.connected ? "正在连接服务…" : "正在启动服务…"
        }
        if state.status == "error" { return "服务启动失败" }
        if !state.ready { return state.message.isEmpty ? "正在加载模型…" : state.message }
        return "准备就绪"
    }

    private var idleSubtitle: String {
        guard let state = backend.state else {
            return "首次启动需要编译 CoreML 模型，请稍候"
        }
        if state.status == "error" {
            return state.error ?? "请查看 logs/native-app.log"
        }
        if !state.ready {
            return state.status == "warming-swapper"
                ? "正在用 CoreML 编译换脸模型，通常 1–3 分钟；编译结果会被缓存。"
                : "首次启动需要加载模型，请稍候。"
        }
        if photos.isEmpty {
            return "先上传一张人像照片，然后点击开始直播"
        }
        return "点击开始直播并允许摄像头"
    }
}

// MARK: - 组件

private struct StatusPill: View {
    @EnvironmentObject private var backend: BackendClient
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let info = statusInfo
        HStack(spacing: 6) {
            Circle()
                .fill(info.color)
                .frame(width: 7, height: 7)
                .shadow(color: info.color.opacity(0.6), radius: 4)
            Text(info.text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.055)))
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var statusInfo: (text: String, color: Color) {
        if model.isRunning { return ("直播中", Color.green) }
        guard let state = backend.state else {
            return (backend.connected ? "连接中" : "启动中", .orange)
        }
        switch state.status {
        case "ready": return ("就绪", .green)
        case "error": return ("错误", Theme.danger)
        case "warming-swapper": return ("预热中", .orange)
        default: return ("加载中", .orange)
        }
    }
}

private struct AppIconBadge: View {
    let size: CGFloat

    private static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let image = AppIconBadge.icon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "person.crop.square.fill")
                    .resizable()
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Theme.accent.opacity(0.22), radius: 10, y: 4)
    }
}

private struct PhotoTile: View {
    let photo: PhotoInfo
    let index: Int
    let isActive: Bool
    @ObservedObject var ui: UIState

    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            AsyncImage(url: URL(string: BackendClient.baseURL.absoluteString + photo.thumb)) { phase in
                switch phase {
                case .empty:
                    ProgressView().controlSize(.small)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.03))
            .clipped()
        }
        .frame(height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Theme.accent : Color.white.opacity(0.08), lineWidth: isActive ? 2 : 1)
        )
        .overlay(alignment: .topLeading) {
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if ui.hoveredPhotoID == photo.id {
                Button {
                    model.deletePhoto(photo.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectPhoto(photo.id) }
        .onHover { hovering in
            if hovering {
                ui.hoveredPhotoID = photo.id
            } else if ui.hoveredPhotoID == photo.id {
                ui.hoveredPhotoID = nil
            }
        }
        .help(photo.name)
    }
}

private struct EmptyUploadTile: View {
    @ObservedObject var ui: UIState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(ui.uploadHover ? Theme.cyan : Theme.accent)
                Text("拖入或点击上传人像照片")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text("JPG / PNG / WEBP · 建议清晰正脸")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent.opacity(ui.uploadHover ? 0.09 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Theme.accent.opacity(ui.uploadHover ? 0.75 : 0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { ui.uploadHover = $0 }
    }
}

private struct UploadTile: View {
    @ObservedObject var ui: UIState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                Text("添加")
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 86)
            .foregroundStyle(ui.uploadHover ? Theme.accent : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ui.uploadHover ? Theme.accent.opacity(0.07) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        ui.uploadHover ? Theme.accent.opacity(0.7) : Theme.accent.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { ui.uploadHover = $0 }
    }
}

private struct MicLevelIndicator: View {
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: active ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 9))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, level)))))
                }
            }
            .frame(width: 42, height: 4)
        }
        .foregroundStyle(active ? Color.green : Color.secondary)
        .help(active ? "麦克风电平" : "未启用麦克风")
    }

    private var barColor: Color {
        if !active { return .gray }
        if level > 0.85 { return Theme.danger }
        if level > 0.6 { return .yellow }
        return .green
    }
}

private struct MetricChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
