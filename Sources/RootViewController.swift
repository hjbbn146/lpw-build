import UIKit
import Photos

/// iOS 原生 inset-grouped 风格的主界面。
///
/// 版面纪律（这几条是硬要求，别改）：
///   1. content 必须和 scroll 的 frameLayoutGuide 等宽（左右各 16）。
///      少了这条约束，结果文本一长就把整页撑宽，看起来像「整个画面被放大了」。
///   2. 所有长文本 label 的 numberOfLines = 0，不许截断。
///   3. 字体走 Theme.font（descriptor 锁死），不跟随动态字体。
final class RootViewController: UIViewController {

    // MARK: - 状态

    private var sourceURL: URL?
    private var pickedInfo: VideoInfo?
    private var picker: VideoPicker?
    private var busy = false

    // MARK: - 控件

    private let scroll = UIScrollView()
    private let content = UIStackView()

    private let pickRow = UIButton(type: .custom)
    private let fileLabel = Ctl.label("尚未选择视频", size: 13, color: Theme.faint)

    private var infoValues: [UILabel] = []

    // iOS 实况照片的硬上限是 3 秒，超过 3 秒一律不被壁纸引擎接受。
    // 所以这里只给合法时长，不提供「保留全长」——那条路只会产出设不了壁纸的文件。
    private let seg = UISegmentedControl(items: ["3 秒", "2 秒", "1 秒"])
    private let audioSwitch = UISwitch()

    private let genButton = Ctl.filledButton("生成实况壁纸", height: 50)

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = Ctl.label("", size: 13, color: Theme.sub)

    private let resultLabel = Ctl.label("尚未生成", size: 13.5, color: Theme.sub)
    private let openPhotosButton = Ctl.tintedButton("打开相册")
    private let selfTestButton = Ctl.tintedButton("环境自检")
    /// 修复：把相册里已有的实况读回来，重新生成一份结构正确的
    private let repairButton = Ctl.tintedButton("修复相册里最近一张实况", height: 44)

    private let logLabel = Ctl.label("", size: 10.5, color: Theme.faint, lines: 10)
    private var logLines: [String] = []

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        Diag.mark("rootVC:viewDidLoad")
        view.backgroundColor = Theme.bg
        buildLayout()
        wireActions()
        observeLog()
        refreshInfo()
        setBusy(false, "")
        Diag.mark("rootVC:laidOut")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }

    // MARK: - 布局

    private func buildLayout() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.bounces = false
        scroll.backgroundColor = .clear
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        content.axis = .vertical
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            // ★ 这一条是「画面变大」的根治：内容宽度必须锁死成视口宽度
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])

        // ---- 大标题
        let title = Ctl.label("无损实况", size: 34, weight: .bold, color: Theme.text)
        let subtitle = Ctl.label("视频转锁屏实况 · 画质零损失", size: 15, color: Theme.sub)
        content.addArrangedSubview(title)
        content.setCustomSpacing(4, after: title)
        content.addArrangedSubview(subtitle)
        content.setCustomSpacing(22, after: subtitle)

        // ---- 视频
        content.addArrangedSubview(Ctl.sectionHeader("视频"))
        content.setCustomSpacing(7, after: content.arrangedSubviews.last!)

        let videoCard = Ctl.card()
        let videoStack = UIStackView()
        videoStack.axis = .vertical
        videoStack.spacing = 0
        videoStack.translatesAutoresizingMaskIntoConstraints = false
        videoCard.addSubview(videoStack)
        NSLayoutConstraint.activate([
            videoStack.topAnchor.constraint(equalTo: videoCard.topAnchor),
            videoStack.leadingAnchor.constraint(equalTo: videoCard.leadingAnchor),
            videoStack.trailingAnchor.constraint(equalTo: videoCard.trailingAnchor),
            videoStack.bottomAnchor.constraint(equalTo: videoCard.bottomAnchor)
        ])

        buildPickRow()
        videoStack.addArrangedSubview(pickRow)
        videoStack.addArrangedSubview(insetSeparator())
        videoStack.addArrangedSubview(fileRow())
        videoStack.addArrangedSubview(insetSeparator())
        videoStack.addArrangedSubview(infoRows())
        content.addArrangedSubview(videoCard)
        content.setCustomSpacing(22, after: videoCard)

        // ---- 输出设置
        content.addArrangedSubview(Ctl.sectionHeader("输出设置"))
        content.setCustomSpacing(7, after: content.arrangedSubviews.last!)

        let outCard = Ctl.card()
        let outStack = UIStackView()
        outStack.axis = .vertical
        outStack.spacing = 0
        outStack.translatesAutoresizingMaskIntoConstraints = false
        outCard.addSubview(outStack)
        NSLayoutConstraint.activate([
            outStack.topAnchor.constraint(equalTo: outCard.topAnchor),
            outStack.leadingAnchor.constraint(equalTo: outCard.leadingAnchor),
            outStack.trailingAnchor.constraint(equalTo: outCard.trailingAnchor),
            outStack.bottomAnchor.constraint(equalTo: outCard.bottomAnchor)
        ])

        seg.selectedSegmentIndex = 0
        applySegmentStyle()
        seg.translatesAutoresizingMaskIntoConstraints = false
        let segBox = UIView()
        segBox.translatesAutoresizingMaskIntoConstraints = false
        segBox.addSubview(seg)
        NSLayoutConstraint.activate([
            seg.topAnchor.constraint(equalTo: segBox.topAnchor, constant: 12),
            seg.leadingAnchor.constraint(equalTo: segBox.leadingAnchor, constant: 16),
            seg.trailingAnchor.constraint(equalTo: segBox.trailingAnchor, constant: -16),
            seg.bottomAnchor.constraint(equalTo: segBox.bottomAnchor, constant: -12),
            seg.heightAnchor.constraint(equalToConstant: 34)
        ])
        outStack.addArrangedSubview(segBox)
        outStack.addArrangedSubview(insetSeparator())

        audioSwitch.onTintColor = Theme.accent
        audioSwitch.isOn = true
        outStack.addArrangedSubview(Ctl.row(icon: nil, title: "保留原声", valueView: audioSwitch))
        content.addArrangedSubview(outCard)
        content.setCustomSpacing(18, after: outCard)

        // ---- 主按钮
        content.addArrangedSubview(genButton)
        content.setCustomSpacing(10, after: genButton)
        content.addArrangedSubview(repairButton)
        content.setCustomSpacing(12, after: repairButton)

        // ---- 状态行
        let statusRow = UIStackView()
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 8
        spinner.hidesWhenStopped = true
        spinner.color = Theme.sub
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        content.addArrangedSubview(statusRow)
        content.setCustomSpacing(22, after: statusRow)

        // ---- 结果
        content.addArrangedSubview(Ctl.sectionHeader("结果"))
        content.setCustomSpacing(7, after: content.arrangedSubviews.last!)

        let resCard = Ctl.card()
        let resStack = UIStackView()
        resStack.axis = .vertical
        resStack.spacing = 12
        resStack.translatesAutoresizingMaskIntoConstraints = false
        resCard.addSubview(resStack)
        NSLayoutConstraint.activate([
            resStack.topAnchor.constraint(equalTo: resCard.topAnchor, constant: 14),
            resStack.leadingAnchor.constraint(equalTo: resCard.leadingAnchor, constant: 16),
            resStack.trailingAnchor.constraint(equalTo: resCard.trailingAnchor, constant: -16),
            resStack.bottomAnchor.constraint(equalTo: resCard.bottomAnchor, constant: -14)
        ])
        resStack.addArrangedSubview(resultLabel)
        resStack.addArrangedSubview(openPhotosButton)
        resStack.addArrangedSubview(selfTestButton)
        content.addArrangedSubview(resCard)
        content.setCustomSpacing(22, after: resCard)

        // ---- 日志
        content.addArrangedSubview(Ctl.sectionHeader("运行日志"))
        content.setCustomSpacing(7, after: content.arrangedSubviews.last!)

        let logCard = Ctl.card()
        let logStack = UIStackView()
        logStack.axis = .vertical
        logStack.spacing = 12
        logStack.translatesAutoresizingMaskIntoConstraints = false
        logCard.addSubview(logStack)
        NSLayoutConstraint.activate([
            logStack.topAnchor.constraint(equalTo: logCard.topAnchor, constant: 14),
            logStack.leadingAnchor.constraint(equalTo: logCard.leadingAnchor, constant: 16),
            logStack.trailingAnchor.constraint(equalTo: logCard.trailingAnchor, constant: -16),
            logStack.bottomAnchor.constraint(equalTo: logCard.bottomAnchor, constant: -14)
        ])
        logStack.addArrangedSubview(logLabel)
        let copyBtn = Ctl.tintedButton("复制日志", height: 40)
        copyBtn.addTarget(self, action: #selector(onCopyLog), for: .touchUpInside)
        logStack.addArrangedSubview(copyBtn)
        content.addArrangedSubview(logCard)
        content.setCustomSpacing(24, after: logCard)

        // ---- 页脚
        content.addArrangedSubview(makeFooter())
    }

    private func insetSeparator() -> UIView {
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        let line = Ctl.separator()
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor)
        ])
        return holder
    }

    private func buildPickRow() {
        pickRow.translatesAutoresizingMaskIntoConstraints = false
        pickRow.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let icon = Ctl.icon("photo.on.rectangle", size: 18)
        let title = Ctl.label("从相册选择视频", size: 16, color: Theme.accent)
        let chev = Ctl.icon("chevron.right", color: Theme.faint, size: 12, weight: .semibold)

        pickRow.addSubview(icon)
        pickRow.addSubview(title)
        pickRow.addSubview(chev)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: pickRow.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: pickRow.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: pickRow.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: chev.leadingAnchor, constant: -8),
            chev.trailingAnchor.constraint(equalTo: pickRow.trailingAnchor, constant: -16),
            chev.centerYAnchor.constraint(equalTo: pickRow.centerYAnchor),
            chev.widthAnchor.constraint(equalToConstant: 10)
        ])
    }

    private func fileRow() -> UIView {
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(fileLabel)
        NSLayoutConstraint.activate([
            fileLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            fileLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            fileLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            fileLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12)
        ])
        return box
    }

    private func infoRows() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        let titles = ["分辨率", "编码格式", "时长", "码率"]
        for (i, t) in titles.enumerated() {
            let v = Ctl.label("—", size: 15, color: Theme.sub)
            v.textAlignment = .right
            v.setContentHuggingPriority(.required, for: .horizontal)
            infoValues.append(v)
            stack.addArrangedSubview(Ctl.row(icon: nil, title: t, valueView: v))
            if i < titles.count - 1 {
                stack.addArrangedSubview(insetSeparator())
            }
        }
        return stack
    }

    private func makeFooter() -> UIView {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 8
        s.addArrangedSubview(Ctl.label("如何设为壁纸", size: 13, weight: .semibold, color: Theme.sub))
        s.addArrangedSubview(Ctl.label(
            "设置 → 墙纸 → 添加新墙纸 → 照片 → 实况照片 → 选中它 → 左下角「实况」点亮 → 设定锁定屏幕",
            size: 12.5, color: Theme.faint))
        s.addArrangedSubview(Ctl.label(
            "亮屏时播一次；低电量模式、减弱动态效果会关掉动效；主屏幕始终静止。",
            size: 12.5, color: Theme.faint))
        return s
    }

    private func applySegmentStyle() {
        seg.selectedSegmentTintColor = Theme.accent
        seg.setTitleTextAttributes([.foregroundColor: Theme.onAccent,
                                    .font: Theme.font(13, .semibold)], for: .selected)
        seg.setTitleTextAttributes([.foregroundColor: Theme.text,
                                    .font: Theme.font(13, .medium)], for: .normal)
    }

    // MARK: - 事件

    private func wireActions() {
        pickRow.addTarget(self, action: #selector(onPick), for: .touchUpInside)
        genButton.addTarget(self, action: #selector(onGenerate), for: .touchUpInside)
        openPhotosButton.addTarget(self, action: #selector(onOpenPhotos), for: .touchUpInside)
        selfTestButton.addTarget(self, action: #selector(onSelfTest), for: .touchUpInside)
        repairButton.addTarget(self, action: #selector(onRepair), for: .touchUpInside)
    }

    @objc private func onPick() {
        guard !busy else { return }
        let p = VideoPicker { [weak self] url in
            guard let self = self else { return }
            self.picker = nil
            guard let url = url else {
                self.statusLabel.text = "没有选到视频"
                return
            }
            self.sourceURL = url
            self.pickedInfo = MediaInspector.inspect(url)
            self.fileLabel.text = url.lastPathComponent
            self.fileLabel.textColor = Theme.text
            self.refreshInfo()
            self.resultLabel.text = "尚未生成"
            self.resultLabel.textColor = Theme.sub
            self.setBusy(false, "已就绪，点下方按钮开始")
        }
        self.picker = p
        present(p.makeController(), animated: true, completion: nil)
    }

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBG() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "lpw.make") { [weak self] in
            guard let self = self, self.bgTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.bgTask)
            self.bgTask = .invalid
        }
    }

    private func endBG() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    @objc private func onGenerate() {
        guard !busy else { return }
        guard let src = sourceURL else {
            statusLabel.text = "请先选择一段视频"
            statusLabel.textColor = Theme.warn
            return
        }
        // 真机实况视频的时长是**正好 3.000 秒**（1800 ticks @600）。
        // 传 3.0 时最后一帧的时间戳常常刚好越过 1800，导出成了 3.02~3.04 秒，
        // 比系统认可的上限多出一点点。这里留一帧余量，保证严格小于标称值。
        let maxSeconds: Double
        switch seg.selectedSegmentIndex {
        case 1: maxSeconds = 1.9
        case 2: maxSeconds = 0.9
        default: maxSeconds = 2.9
        }
        let audio = audioSwitch.isOn

        resultLabel.text = "处理中…"
        resultLabel.textColor = Theme.sub
        statusLabel.textColor = Theme.sub
        setBusy(true, "准备中…")
        beginBG()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let made = try LivePhotoMaker.make(source: src,
                                                   maxSeconds: maxSeconds,
                                                   keepAudio: audio) { s in
                    DispatchQueue.main.async { self.statusLabel.text = s }
                }
                self.keepCopy(made)

                DispatchQueue.main.async { self.statusLabel.text = "写入相册…" }
                let lid = try PhotoSaver.savePair(photo: made.photoURL, video: made.videoURL)
                let live = PhotoSaver.waitPhotoLive(localIdentifier: lid)

                let chk = LiveCheck.verify(
                    videoURL: made.videoURL,
                    stillSize: CGSize(width: made.info.width, height: made.info.height))
                Diag.log("产物结构自检：" + chk.summary)

                let mb = self.fileMB(made.videoURL)
                let photoMB = self.fileMB(made.photoURL)

                DispatchQueue.main.async {
                    self.endBG()
                    if chk.ok {
                        self.setBusy(false, "完成 · 结构完整")
                        self.resultLabel.text = String(format:
                            "已生成：HEVC + 实况元数据轨齐全\n动态 %.2f MB · 静帧 %.2f MB · %d×%d\n\n按下方说明设为锁屏壁纸。",
                            mb, photoMB, made.info.width, made.info.height)
                        self.resultLabel.textColor = Theme.text
                    } else {
                        self.setBusy(false, "结构不完整")
                        self.resultLabel.text = String(format:
                            "%@\n动态 %.2f MB · 静帧 %.2f MB\n相册里可能只显示成普通照片，把日志发给开发者",
                            chk.summary, mb, photoMB)
                        self.resultLabel.textColor = Theme.warn
                    }
                    if !live {
                        Diag.log("注意：PhotoKit 没把资产标成实况（mediaSubtypes 无 photoLive）")
                    }
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async {
                    self.endBG()
                    self.setBusy(false, "失败")
                    self.resultLabel.text = msg
                    self.resultLabel.textColor = Theme.danger
                }
            }
        }
    }

    @objc private func onSelfTest() {
        guard !busy else { return }
        setBusy(true, "自检中…")
        resultLabel.text = "正在跑完整链路自检…"
        resultLabel.textColor = Theme.sub
        SelfTest.run(step: { [weak self] line in
            self?.statusLabel.text = line
        }, finish: { [weak self] summary in
            guard let self = self else { return }
            self.endBG()
            self.setBusy(false, "自检结束")
            self.resultLabel.text = summary
            self.resultLabel.textColor = summary.hasPrefix("自检全部通过") || summary.contains("✅")
                ? Theme.ok : Theme.warn
        })
        beginBG()
    }

    /// 修复相册里最近一张实况：读回它的配对视频，重新直通 + 截断 + 重移植 + 重写静帧。
    ///
    /// 为什么不做「原地补 box」：旧产物可能缺轨、可能超长（>3 秒）、静帧还可能是
    /// ImageIO 写的 JPG（MakerNote 被丢）。重新走一遍直通能一次性全修好，
    /// 而且直通不重编码，画质不损失。
    @objc private func onRepair() {
        guard !busy else { return }
        resultLabel.text = "正在查找相册里最近一张实况…"
        resultLabel.textColor = Theme.sub
        statusLabel.textColor = Theme.sub
        setBusy(true, "准备修复…")
        beginBG()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                guard LiveRepair.requestReadPermission() else {
                    throw MakeError.msg("修复需要「完全访问」相册，因为要把旧实况的配对视频读回来。\n"
                                        + "设置 → 隐私与安全性 → 照片 → 无损实况 → 完全访问")
                }
                guard let asset = LiveRepair.latestLiveAsset() else {
                    throw MakeError.msg("相册里没找到实况照片。\n先用上面「生成实况壁纸」做一张，再用这个按钮修。")
                }
                let diag = LiveRepair.diagnose(asset)
                Diag.log("修复目标：" + diag)
                DispatchQueue.main.async { self.statusLabel.text = "旧的：" + diag }

                let made = try LiveRepair.repair(asset, maxSeconds: 2.9) { s in
                    DispatchQueue.main.async { self.statusLabel.text = s }
                }
                self.keepCopy(made)

                DispatchQueue.main.async { self.statusLabel.text = "写入相册…" }
                let lid = try PhotoSaver.savePair(photo: made.photoURL, video: made.videoURL)
                _ = PhotoSaver.waitPhotoLive(localIdentifier: lid)

                let chk = LiveCheck.verify(
                    videoURL: made.videoURL,
                    stillSize: CGSize(width: made.info.width, height: made.info.height))
                Diag.log("修复产物自检：" + chk.summary)

                let mb = self.fileMB(made.videoURL)
                let photoMB = self.fileMB(made.photoURL)

                DispatchQueue.main.async {
                    self.endBG()
                    if chk.ok {
                        self.setBusy(false, "修复完成 · 结构完整")
                        self.resultLabel.text = String(format:
                            "✅ 已修复，相册里多了一张新的\n原状态：%@\n新产物：HEVC + 元数据轨齐全\n动态 %.2f MB · 静帧 %.2f MB\n\n设壁纸请用新生成的这张，旧的可以删掉。",
                            diag, mb, photoMB)
                        self.resultLabel.textColor = Theme.text
                    } else {
                        self.setBusy(false, "修复后仍不完整")
                        self.resultLabel.text = "⚠️ " + chk.summary
                            + "\n\n把日志（下方「复制日志」）发给开发者。"
                        self.resultLabel.textColor = Theme.warn
                    }
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async {
                    self.endBG()
                    self.setBusy(false, "修复失败")
                    self.resultLabel.text = msg
                    self.resultLabel.textColor = Theme.danger
                }
            }
        }
    }

    @objc private func onCopyLog() {
        let text = (try? String(contentsOf: Diag.logURL, encoding: .utf8)) ?? logLines.joined(separator: "\n")
        let boot = (try? String(contentsOf: Diag.bootURL, encoding: .utf8)) ?? ""
        let crash = CrashCatcher.readAll()
        var all = "=== boot.log ===\n" + boot + "\n=== lpw.log ===\n" + text
        if !crash.isEmpty { all += "\n=== crash.log ===\n" + crash }
        UIPasteboard.general.string = all
        statusLabel.textColor = Theme.sub
        statusLabel.text = crash.isEmpty ? "日志已复制到剪贴板" : "日志已复制（含崩溃记录）"
    }

    @objc private func onOpenPhotos() {
        PhotoSaver.openPhotosApp()
    }

    // MARK: - 辅助

    private func refreshInfo() {
        guard let i = pickedInfo else {
            for v in infoValues { v.text = "—" }
            return
        }
        let vals = ["\(i.width)×\(i.height)",
                    i.codec + (i.bitDepth > 8 ? " \(i.bitDepth)bit" : "") + (i.isHDR ? " HDR" : ""),
                    MediaInspector.durationText(i.duration),
                    MediaInspector.bitrateText(i.bitRate)]
        for (k, v) in vals.enumerated() where k < infoValues.count {
            infoValues[k].text = v
        }
    }

    private func setBusy(_ b: Bool, _ text: String) {
        busy = b
        genButton.isEnabled = !b
        pickRow.isEnabled = !b
        genButton.alpha = b ? 0.45 : 1
        pickRow.alpha = b ? 0.55 : 1
        if b { spinner.startAnimating() } else { spinner.stopAnimating() }
        if !text.isEmpty { statusLabel.text = text }
    }

    private func fileMB(_ url: URL) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.doubleValue ?? 0
        return size / 1_048_576.0
    }

    private func keepCopy(_ made: MadeLive) {
        let fm = FileManager.default
        for src in [made.videoURL, made.photoURL] {
            let dst = Diag.dir.appendingPathComponent("out_" + src.lastPathComponent)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        Diag.log("产物副本已保存到 Documents")
    }

    private func observeLog() {
        _ = NotificationCenter.default.addObserver(forName: .lpwLog, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let line = n.userInfo?["line"] as? String else { return }
            self.logLines.append(line)
            if self.logLines.count > 10 {
                self.logLines.removeFirst(self.logLines.count - 10)
            }
            self.logLabel.text = self.logLines.joined(separator: "\n")
        }
    }
}
