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
    @Published var showSettings = false
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
        .sheet(isPresented: $ui.showSettings) {
            SettingsView(isPresented: $ui.showSettings)
                .environmentObject(backend)
                .environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveFaceOpenSettings)) { _ in
            ui.showSettings = true
        }
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
            Button {
                ui.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("设置（⌘,）")
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
                Text("直播设置")
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

            Text(model.isRunning
                 ? "\(Int(model.displayedSize.width))×\(Int(model.displayedSize.height)) · 实时换脸中"
                 : "摄像头未开启")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if model.isRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isRecordingPaused ? Color.orange : Theme.danger)
                        .frame(width: 6, height: 6)
                    Text((model.isRecordingPaused ? "PAUSED " : "REC ") + model.recordTimeText)
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(model.isRecordingPaused ? Color.orange : Theme.danger)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill((model.isRecordingPaused ? Color.orange : Theme.danger).opacity(0.12)))
                .overlay(Capsule().stroke((model.isRecordingPaused ? Color.orange : Theme.danger).opacity(0.35), lineWidth: 1))

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

            if model.isRecording {
                Button {
                    model.toggleRecordingPause()
                } label: {
                    Image(systemName: model.isRecordingPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(model.isRecordingPaused ? "继续录制（⌘P）" : "暂停录制（⌘P）")
            }

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
            Text("空格 开始/停止 · 1–9 换人 · ⌘S 截图 · ⌘R 录制 · ⌘P 暂停")
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
