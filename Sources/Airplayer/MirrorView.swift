// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import QuartzCore

final class MirrorView: NSView {
    private let videoView = try? MetalVideoView(rendering: true)
    var renderingError: String? { videoView == nil ? "无法初始化 Metal 视频显示。" : nil }
    var submittedFrames: UInt64 { videoView?.submittedFrames ?? 0 }
    var latencySummary: String { videoView?.timings.summary ?? "" }
    var onStats: ((String) -> Void)? {
        didSet { videoView?.onStats = onStats }
    }
    private let waiting = NSView()
    private let symbol = NSImageView()
    private let heading = NSTextField(labelWithString: "等待投屏")
    private let instructions = NSTextField(wrappingLabelWithString: "在 Apple 设备上打开「屏幕镜像」，选择")
    private let receiverName: NSTextField
    private let statusDot = NSView()
    private let statusText = NSTextField(labelWithString: "正在启动…")
    private let hint = NSTextField(labelWithString: "双击画面全屏 · Esc 退出全屏")
    private let fullscreenButton = NSButton()
    private var mirrored = false
    var toggleFullscreen: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { !mirrored }

    init(deviceName: String) {
        receiverName = NSTextField(labelWithString: deviceName)
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.045, green: 0.052, blue: 0.065, alpha: 1).cgColor
        if let videoView {
            videoView.isHidden = true
            videoView.autoresizingMask = [.width, .height]
            addSubview(videoView)
            videoView.onError = { [weak self] message in self?.setState(.failed(message)) }
        }
        addSubview(waiting)
        symbol.image = NSImage(systemSymbolName: "airplay.video", accessibilityDescription: "屏幕镜像")
        symbol.contentTintColor = NSColor(red: 0.62, green: 0.72, blue: 0.92, alpha: 1)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 56, weight: .ultraLight)
        symbol.imageScaling = .scaleProportionallyUpOrDown
        waiting.addSubview(symbol)
        heading.font = .systemFont(ofSize: 28, weight: .medium)
        heading.textColor = NSColor(white: 0.94, alpha: 1)
        instructions.font = .systemFont(ofSize: 14)
        instructions.textColor = NSColor(white: 0.60, alpha: 1)
        instructions.alignment = .center
        instructions.maximumNumberOfLines = 3
        receiverName.font = .systemFont(ofSize: 15, weight: .medium)
        receiverName.textColor = NSColor(white: 0.84, alpha: 1)
        receiverName.lineBreakMode = .byTruncatingTail
        receiverName.alignment = .center
        receiverName.isSelectable = true
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusText.font = .systemFont(ofSize: 12)
        statusText.textColor = NSColor(white: 0.52, alpha: 1)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 0.47, alpha: 1)
        hint.alignment = .center
        for view in [heading, instructions, receiverName, statusDot, statusText, hint] { waiting.addSubview(view) }
        fullscreenButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: "切换全屏")
        fullscreenButton.contentTintColor = NSColor(white: 0.65, alpha: 1)
        fullscreenButton.bezelStyle = .inline
        fullscreenButton.isBordered = false
        fullscreenButton.target = self
        fullscreenButton.action = #selector(fullscreen)
        fullscreenButton.toolTip = "全屏（⌃⌘F）"
        fullscreenButton.setAccessibilityLabel("切换全屏")
        addSubview(fullscreenButton)
        setState(.starting)
        setAccessibilityElement(true)
        setAccessibilityLabel("Airplayer 投屏窗口")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView?.frame = bounds
        CATransaction.commit()
        waiting.frame = bounds
        let center = bounds.midX
        let baseline = bounds.midY + 8
        symbol.frame = NSRect(x: center - 36, y: baseline + 57, width: 72, height: 62)
        heading.sizeToFit()
        heading.frame.origin = NSPoint(x: center - heading.frame.width / 2, y: baseline + 4)
        instructions.frame = NSRect(x: 32, y: baseline - 65, width: bounds.width - 64, height: 48)
        receiverName.frame = NSRect(x: 40, y: baseline - 94, width: bounds.width - 80, height: 24)
        statusText.sizeToFit()
        let statusWidth = statusText.frame.width + 16
        statusDot.frame = NSRect(x: center - statusWidth / 2, y: 65, width: 6, height: 6)
        statusText.frame.origin = NSPoint(x: center - statusWidth / 2 + 16, y: 60)
        hint.frame = NSRect(x: 20, y: 28, width: bounds.width - 40, height: 18)
        fullscreenButton.frame = NSRect(x: bounds.width - 49, y: bounds.height - 50, width: 28, height: 28)
    }

    func display(_ frame: SurfaceFrame?) {
        mirrored = frame != nil
        videoView?.isHidden = !mirrored
        videoView?.display(frame)
        waiting.isHidden = mirrored
        fullscreenButton.isHidden = mirrored
        setAccessibilityValue(mirrored ? "正在投屏" : "等待设备连接")
    }

    func setState(_ state: ReceiverState) {
        switch state {
        case .starting:
            heading.stringValue = "正在准备投屏"
            instructions.stringValue = "接收器将在启动后自动等待设备连接"
            statusText.stringValue = "正在启动…"
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .ready:
            heading.stringValue = "等待投屏"
            instructions.stringValue = "在 Apple 设备上打开「屏幕镜像」，选择"
            receiverName.isHidden = false
            statusText.stringValue = "已就绪 · 请连接同一 Wi-Fi 或局域网"
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case .mirroring:
            break
        case .failed(let message):
            display(nil)
            heading.stringValue = "暂时无法投屏"
            instructions.stringValue = message
            receiverName.isHidden = true
            statusText.stringValue = "接收器未就绪"
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        }
        needsLayout = true
    }

    @objc private func fullscreen() { toggleFullscreen?() }

    #if AIRPLAYER_DIAGNOSTICS
    func snapshotVideoImage() -> CGImage? { videoView?.snapshotImage() }
    #endif

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { toggleFullscreen?() }
        else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, window?.styleMask.contains(.fullScreen) == true {
            toggleFullscreen?()
        } else { super.keyDown(with: event) }
    }
}
