import UIKit
import Photos
import AVFoundation

final class RootViewController: UIViewController {

    // MARK: - 状态

    private var sourceURL: URL?
    private var pickedInfo: VideoInfo?
    private var picker: VideoPicker?
    private var busy = false

    // MARK: - 控件

    private let scroll = UIScrollView()
    private let content = UIStackView()

    private let fileLabel = Ctl.label("尚未选择视频", size: 12.5, color: Theme.faint, lines: 2)
    private let pickButton = Ctl.button("从相册选择视频", bg: Theme.accent, fg: UIColor(red: 0.02, green: 0.06, blue: 0.05, alpha: 1), height: 50)

    private var infoValues: [UILabel] = []

    private let seg = UISegmentedControl(items: ["3 秒", "5 秒", "保留全长"])
    private let audioSwitch = UISwitch()

    private let genButton = Ctl.button("生成实况壁纸", bg: Theme.accent, fg: UIColor(red: 0.02, green: 0.06, blue: 0.05, alpha: 1), height: 56, size: 17)

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = Ctl.label("", size: 12.5, color: Theme.sub, lines: 4)

    private let resultLabel = Ctl.label("尚未生成", size: 13, color: Theme.sub, lines: 3)
    private let openPhotosButton = Ctl.button("打开相册", bg: Theme.cardInner, fg: Theme.text, height: 42, size: 14)

    private let logLabel = Ctl.label("", size: 10, color: Theme.faint, lines: 9, mono: true)
    private var logLines: [String] = []

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        Diag.mark("rootVC:viewDidLoad")
        buildBackground()
        buildLayout()
        wireActions()
        observeLog()
        refreshInfo()
        setBusy(false, "")
        Diag.mark("rootVC:laidOut")
    }

    // MARK: - 背景

    private func buildBackground() {
        view.backgroundColor = Theme.background
        let bg = UIImageView()
        bg.image = Ctl.gradientImage(size: CGSize(width: 400, height: 900))
        bg.contentMode = .scaleToFill
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - 布局

    private func buildLayout() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        content.axis = .vertical
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -30)
        ])

        // 标题
        let titleRow = UIStackView()
        titleRow.axis = .vertical
        titleRow.spacing = 4
        titleRow.addArrangedSubview(Ctl.label("无损实况", size: 30, weight: .bold, color: Theme.text))
        titleRow.addArrangedSubview(Ctl.label("视频 → 锁屏实况 · 零重编码直通", size: 13, color: Theme.sub))
        titleRow.setCustomSpacing(0, after: titleRow.arrangedSubviews[0])
        content.addArrangedSubview(titleRow)
        content.setCustomSpacing(18, after: titleRow)

        // 卡片 1：选视频
        let (card1, s1) = cardBox("第 1 步 · 选择视频")
        s1.addArrangedSubview(pickButton)
        s1.addArrangedSubview(fileLabel)
        content.addArrangedSubview(card1)

        // 卡片 2：视频信息
        let (card2, s2) = cardBox("视频信息")
        s2.addArrangedSubview(makeInfoGrid())
        content.addArrangedSubview(card2)

        // 卡片 3：输出设置
        let (card3, s3) = cardBox("输出设置")
        seg.selectedSegmentIndex = 0
        seg.selectedSegmentTintColor = Theme.accent
        seg.setTitleTextAttributes([.foregroundColor: UIColor(red: 0.02, green: 0.06, blue: 0.05, alpha: 1),
                                    .font: Theme.font(13, .semibold)], for: .selected)
        seg.setTitleTextAttributes([.foregroundColor: Theme.sub,
                                    .font: Theme.font(13, .medium)], for: .normal)
        seg.translatesAutoresizingMaskIntoConstraints = false
        seg.heightAnchor.constraint(equalToConstant: 34).isActive = true
        s3.addArrangedSubview(seg)

        let audioRow = UIStackView()
        audioRow.axis = .horizontal
        audioRow.alignment = .center
        audioRow.addArrangedSubview(Ctl.label("保留原声", size: 15, weight: .medium, color: Theme.text))
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        audioRow.addArrangedSubview(spacer)
        audioSwitch.onTintColor = Theme.accent
        audioSwitch.isOn = true
        audioRow.addArrangedSubview(audioSwitch)
        s3.addArrangedSubview(audioRow)
        s3.setCustomSpacing(16, after: seg)

        s3.addArrangedSubview(Ctl.label("画面按源分辨率与码率原样保留，不缩放、不二次编码。",
                                       size: 11.5, color: Theme.faint, lines: 2))
        content.addArrangedSubview(card3)

        // 主按钮
        content.addArrangedSubview(genButton)

        // 状态
        let statusRow = UIStackView()
        statusRow.axis = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 8
        spinner.hidesWhenStopped = true
        spinner.color = Theme.sub
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        content.addArrangedSubview(statusRow)

        // 结果
        let (card4, s4) = cardBox("结果")
        s4.addArrangedSubview(resultLabel)
        s4.addArrangedSubview(openPhotosButton)
        content.addArrangedSubview(card4)

        // 日志
        let (card5, s5) = cardBox("运行日志")
        s5.addArrangedSubview(logLabel)
        let copyBtn = Ctl.button("复制日志", bg: Theme.cardInner, fg: Theme.sub, height: 36, size: 13)
        copyBtn.addTarget(self, action: #selector(onCopyLog), for: .touchUpInside)
        s5.addArrangedSubview(copyBtn)
        content.addArrangedSubview(card5)

        content.addArrangedSubview(makeFooter())
    }

    private func cardBox(_ tag: String) -> (UIView, UIStackView) {
        let card = Ctl.card()
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 10
        s.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            s.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            s.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            s.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        let t = Ctl.sectionTag(tag.uppercased())
        s.addArrangedSubview(t)
        s.setCustomSpacing(8, after: t)
        return (card, s)
    }

    private func makeInfoGrid() -> UIView {
        var rows: [UIStackView] = []
        let titles = ["分辨率", "编码", "时长", "码率"]
        for r in 0..<2 {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually
            for c in 0..<2 {
                let idx = r * 2 + c
                let (box, val) = infoCell(titles[idx])
                infoValues.append(val)
                row.addArrangedSubview(box)
            }
            rows.append(row)
        }
        let outer = UIStackView(arrangedSubviews: rows)
        outer.axis = .vertical
        outer.spacing = 10
        return outer
    }

    private func infoCell(_ title: String) -> (UIView, UILabel) {
        let box = UIView()
        box.backgroundColor = Theme.cardInner
        box.layer.cornerRadius = 12
        box.layer.cornerCurve = .continuous
        box.translatesAutoresizingMaskIntoConstraints = false

        let t = Ctl.label(title, size: 10.5, weight: .medium, color: Theme.faint)
        let v = Ctl.label("—", size: 13.5, weight: .semibold, color: Theme.text)
        box.addSubview(t)
        box.addSubview(v)
        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            t.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            t.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -10),
            v.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 3),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            v.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -10),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)
        ])
        return (box, v)
    }

    private func makeFooter() -> UIView {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 6
        s.addArrangedSubview(Ctl.label("设置壁纸",
                                      size: 12, weight: .semibold, color: Theme.sub))
        s.addArrangedSubview(Ctl.label("设置 → 墙纸 → 添加新墙纸 → 照片 → 实况照片 → 选中它 → 设定锁定屏幕",
                                      size: 11.5, color: Theme.faint, lines: 3))
        s.addArrangedSubview(Ctl.label("亮屏时播一次；低电量模式、减弱动态效果会关掉动效；主屏幕始终静止。",
                                      size: 11.5, color: Theme.faint, lines: 3))
        return s
    }

    // MARK: - 事件

    private func wireActions() {
        pickButton.addTarget(self, action: #selector(onPick), for: .touchUpInside)
        genButton.addTarget(self, action: #selector(onGenerate), for: .touchUpInside)
        openPhotosButton.addTarget(self, action: #selector(onOpenPhotos), for: .touchUpInside)
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
            self.fileLabel.textColor = Theme.sub
            self.refreshInfo()
            self.resultLabel.text = "尚未生成"
            self.resultLabel.textColor = Theme.sub
            self.setBusy(false, "已就绪，点下方按钮开始")
        }
        self.picker = p
        present(p.makeController(), animated: true, completion: nil)
    }

    @objc private func onGenerate() {
        guard !busy else { return }
        guard let src = sourceURL else {
            statusLabel.text = "请先选择一段视频"
            return
        }
        let idx = seg.selectedSegmentIndex
        let maxSeconds: Double
        switch idx {
        case 1: maxSeconds = 5
        case 2: maxSeconds = 0        // 0 = 不截断
        default: maxSeconds = 3
        }
        let audio = audioSwitch.isOn

        resultLabel.text = "处理中…"
        resultLabel.textColor = Theme.sub
        setBusy(true, "准备中…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let made = try LivePhotoMaker.make(source: src,
                                                   maxSeconds: maxSeconds,
                                                   keepAudio: audio) { s in
                    DispatchQueue.main.async { self.statusLabel.text = s }
                }

                // 产物副本留一份到 Documents，方便出问题时取证
                self.keepCopy(made)

                DispatchQueue.main.async { self.statusLabel.text = "写入相册…" }
                let lid = try PhotoSaver.savePair(photo: made.photoURL, video: made.videoURL)
                let live = PhotoSaver.waitPhotoLive(localIdentifier: lid)

                let mb = self.fileMB(made.videoURL)
                let photoMB = self.fileMB(made.photoURL)

                DispatchQueue.main.async {
                    self.setBusy(false, live ? "完成 · 已识别为实况照片" : "已写入相册，但系统未标为实况")
                    if live {
                        self.resultLabel.text = String(format:
                            "✅ 实况照片已生成\n动态 %.2f MB · 静帧 %.2f MB\n分辨率 %d×%d（与源一致）",
                            mb, photoMB, made.info.width, made.info.height)
                        self.resultLabel.textColor = Theme.accent
                    } else {
                        self.resultLabel.text = String(format:
                            "⚠️ 相册里是普通照片 + 视频\n动态 %.2f MB · 静帧 %.2f MB\n请点「打开相册」确认，并把 lpw.log 发给开发者",
                            mb, photoMB)
                        self.resultLabel.textColor = Theme.warn
                    }
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async {
                    self.setBusy(false, "失败")
                    self.resultLabel.text = "❌ " + msg
                    self.resultLabel.textColor = Theme.danger
                }
            }
        }
    }

    @objc private func onCopyLog() {
        let text = (try? String(contentsOf: Diag.logURL, encoding: .utf8)) ?? logLines.joined(separator: "\n")
        let boot = (try? String(contentsOf: Diag.bootURL, encoding: .utf8)) ?? ""
        UIPasteboard.general.string = "=== boot.log ===\n" + boot + "\n=== lpw.log ===\n" + text
        statusLabel.text = "日志已复制到剪贴板"
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
        pickButton.isEnabled = !b
        genButton.alpha = b ? 0.5 : 1
        pickButton.alpha = b ? 0.6 : 1
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
        for (src, prefix) in [(made.videoURL, "out_"), (made.photoURL, "out_")] {
            let dst = Diag.dir.appendingPathComponent(prefix + src.lastPathComponent)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        Diag.log("产物副本已保存到 Documents")
    }

    private func observeLog() {
        NotificationCenter.default.addObserver(forName: .lpwLog, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let line = n.userInfo?["line"] as? String else { return }
            self.logLines.append(line)
            if self.logLines.count > 9 {
                self.logLines.removeFirst(self.logLines.count - 9)
            }
            self.logLabel.text = self.logLines.joined(separator: "\n")
        }
    }
}
