import Foundation

/// 把真机原生实况 MOV 里的 3 条元数据轨，整条移植到我们直通出来的 MOV 上。
///
/// 不重编码、不解码、不动一帧画面：视频 mdat 原封不动在前面，
/// 元数据 sample 追加到第二个 mdat，moov 重新拼一次。
///
/// 输出的轨结构必须与真机样本一模一样：
///   trak1 vide(hvc1) · trak2 meta(live-photo-info) · trak3 meta(still-image-time)
///   · moov/meta(含 content.identifier)
///
/// 与真机自己拍的实况照片完全同构（真机是 vide + soun + live-photo-info + still-image-time，
/// 我们不做音频轨，所以少一条 soun）。**不写 video-orientation**，原因见 donorOrder 注释。
enum MetaTrakPorter {

    struct Report {
        var tracks: [String] = []
        var sampleBytes = 0
        var outputBytes = 0
        /// still-image-time 指向的时刻（秒）。静帧画面必须取同一时刻，
        /// 否则照片内容和实况封面帧对不上。
        var stillSeconds: Double = 0
    }

    enum PortError: LocalizedError {
        case msg(String)
        var errorDescription: String? {
            switch self { case .msg(let s): return s }
        }
    }

    /// 只移植这两条轨。
    ///
    /// **为什么不要 video-orientation**（真机取证，2026-11-19）：
    /// 从 iPhone15,4 相册拉下 6 组配对文件逐 box 比对，
    /// 真机自己拍的（p0066，HEVC 1080×1920 单位矩阵）和第三方能用的产物（p0061/62/63/65）
    /// **全都没有 video-orientation 这条轨**，只有我们内置样本里有。
    /// 而它的值是 int16 = 6（表示要再转 90°）。我们的视频已经通过 tkhd matrix
    /// 带上了 90° 旋转（竖屏拍摄的 3840×2160 编码），两条信息叠加等于转了两次：
    /// 竖屏被转成横屏，且照片（已按显示方向取成竖图）与视频显示尺寸对不上，
    /// 壁纸引擎判定不可用。去掉它之后，方向只由 tkhd matrix 一个来源决定。
    static let donorOrder = ["live-photo-info", "still-image-time"]

    /// 真机原生的 still-image-time sample 内容（89 字节）。
    ///
    /// 与 iPhone15,4 / iOS 27.2 自己拍的实况**逐字节一致**：
    ///   atom key=1  size=9   0xFF            静帧标记
    ///   atom key=2  size=80  3×3 单位矩阵     照片相对视频帧的变换
    ///
    /// 内置样本那份还多一个 key=3（transform-reference-dimensions 1920×1440），
    /// 真机没有；矩阵也带透视分量。两者都不能照搬，否则封面会被判不合法。
    static let canonicalStillSample: [UInt8] = {
        var s: [UInt8] = []
        s += [0, 0, 0, 9, 0, 0, 0, 1, 0xFF]
        s += [0, 0, 0, 80, 0, 0, 0, 2]
        let one: [UInt8]  = [0x3F, 0xF0, 0, 0, 0, 0, 0, 0]   // IEEE754 double 1.0
        let zero: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
        s += one + zero + zero
        s += zero + one + zero
        s += zero + zero + one
        return s
    }()

    // MARK: - 入口

    /// 原地把 videoURL 重写成带完整实况元数据轨的版本（成功后原文件被覆盖）
    ///
    /// - Parameter stillSecondsOverride: 运行期指定封面时刻（秒）。nil 时沿用默认 0.5s 逻辑。
    ///   用于封面自动搜索：换一个封面时刻重新移植，直到系统验证通过。
    @discardableResult
    static func port(videoURL: URL,
                     sampleURL: URL,
                     stillSecondsOverride: Double? = nil) throws -> Report {
        let sData = [UInt8](try Data(contentsOf: sampleURL))
        let sTop = BoxKit.boxes(sData, 0, sData.count)
        guard let sMoov = sTop.first(where: { $0.type == "moov" }) else {
            throw PortError.msg("内置样本损坏：找不到 moov")
        }
        let sTraks = BoxKit.children(sData, sMoov).filter { $0.type == "trak" }

        var donor: [(key: String, box: BoxKit.Box)] = []
        for tk in sTraks where handler(sData, tk) == "meta" {
            let k = keyTag(sData, tk)
            if donorOrder.contains(k) { donor.append((k, tk)) }
        }
        donor.sort { (donorOrder.firstIndex(of: $0.key) ?? 9) < (donorOrder.firstIndex(of: $1.key) ?? 9) }
        guard donor.count == donorOrder.count else {
            throw PortError.msg("内置样本缺少元数据轨（找到 \(donor.map { $0.key })）")
        }

        // ---- 视频侧：扫顶层 box，只要 moov 在最后这一种布局
        let (vTop, fileSize) = try scanTop(videoURL)
        guard let vMoov = vTop.first(where: { $0.type == "moov" }) else {
            throw PortError.msg("直通产物里找不到 moov")
        }
        let prefixEnd = vMoov.off
        guard prefixEnd + vMoov.size == fileSize else {
            throw PortError.msg("直通产物的 moov 不在文件尾部（\(vMoov.off)+\(vMoov.size)≠\(fileSize)），布局不支持移植")
        }
        let vMoovData = try readRange(videoURL, offset: prefixEnd, length: vMoov.size)
        let vMoovBox = BoxKit.Box(type: "moov", off: 0, size: vMoov.size, hdr: vMoov.hdr)
        let vKids = BoxKit.children(vMoovData, vMoovBox)

        guard let mvhd = vKids.first(where: { $0.type == "mvhd" }) else {
            throw PortError.msg("moov 里没有 mvhd")
        }
        let vTraks = vKids.filter { $0.type == "trak" && handler(vMoovData, $0) == "vide" }
        guard let vTrak = vTraks.first else {
            throw PortError.msg("直通产物里没有视频轨")
        }
        let metas = vKids.filter { $0.type == "meta" }

        // 视频时长（统一到 600 时基，实况照片的元数据轨都是这个时基）
        let (vTimescale, vDur) = mdhdInfo(vMoovData, vTrak)
        let durTicks = vTimescale == 600 ? vDur : (vTimescale > 0 ? vDur * 600 / vTimescale : vDur)

        // 静帧时刻：必须精确落在视频正中间那一帧上
        // （元数据轨的时基固定 600，视频轨不是 600 时要换算）
        // 静帧时刻：**固定 0.5 秒**，不是视频中间。
        //
        // 三个「确定能设壁纸」的样本全部落在 0.5 秒：
        //   p0066  真机自拍     视频 1.000s → SIT elst empty 22050 @mvhd 44100 = 0.5s
        //   p0061  第三方 App   视频 0.983s → 22050 @44100 = 0.5s
        //   p0065  第三方 App   视频 0.767s → 300    @600    = 0.5s
        // 而内置样本/模板是「视频中间」（3.0s → 1.533s）—— 中间值在短视频上会离 0.5 秒很远，
        // 与上面三个可用样本都不一致。老板「拖动视频轨换封面就好」正是因为
        // Photos 默认把封面落在靠前的位置。
        let stillRaw = stillPointPts(vMoovData, vTrak, timescale: vTimescale)
        let stillPtsBase = (vTimescale == 600 || vTimescale == 0)
            ? stillRaw.pts : stillRaw.pts * 600 / vTimescale
        // 封面搜索：调用方指定时刻时，换算到 600 时基并夹在 [0, durTicks) 内。
        // 系统只接受精确落在真实帧起点上的时刻，所以再对到不晚于目标的最后一帧。
        let stillPts: Int = {
            guard let ov = stillSecondsOverride, ov.isFinite, ov > 0 else { return stillPtsBase }
            let target = Int((ov * 600.0).rounded())
            return alignToFrame(target, in: vMoovData, vTrak, timescale: vTimescale,
                                fallback: stillPtsBase, durationTicks: durTicks)
        }()
        // elst 的 segment_duration 用 **movie timescale**，不是 media timescale
        let movieTs: Int = {
            let mv = vMoovData[mvhd.off + 8]
            let off = mvhd.off + 8 + (mv == 0 ? 12 : 20)
            guard off + 4 <= vMoovData.count else { return 600 }
            let v = Int(BoxKit.u32(vMoovData, off))
            return v > 0 ? v : 600
        }()
        let stillInMovieTs = stillPts * movieTs / 600
        Diag.log("移植：视频 \(stillRaw.frames) 帧 · 静帧落在 \(stillPts)/600 秒 = "
                 + String(format: "%.3f", Double(stillPts) / 600.0)
                 + "s （movie ts=\(movieTs) → elst \(stillInMovieTs)）")

        // ---- 收集元数据 sample
        let md2Base = prefixEnd + 8          // mdat2 头 8 字节
        var mdat2: [UInt8] = []
        var rebuilt: [String: [UInt8]] = [:]

        for (key, tk) in donor {
            let (chs, coKind) = chunks(sData, tk)
            var newOffs: [Int] = []
            var data: [UInt8] = []
            for c in chs {
                newOffs.append(md2Base + mdat2.count + data.count)
                var p = c.off
                for sz in c.sizes {
                    let hi = min(sData.count, p + sz)
                    if p < hi { data.append(contentsOf: sData[p..<hi]) }
                    p += sz
                }
            }

            // 1.2) live-photo-info：采样点循环补齐到 60Hz 覆盖整段视频
            //
            // 样本只有 74 个点（stsz fixed=144），真机是 60Hz、点数≈秒数×60。
            // 每个点是 144 字节传感器采样，循环复制即可（数据内容本身壁纸引擎不逐点校验，
            // 关键是点数/时基/时长自洽）。补齐后 stsz count / stsc / stco 都要同步重建。
            var lpiTargetSamples = 0
            if key == "live-photo-info" {
                let secs = Double(durTicks) / 600.0
                lpiTargetSamples = max(57, Int(round(secs * 60)))
                if !data.isEmpty {
                    let sampleBytes = 144
                    let have = data.count / sampleBytes
                    var extended = data
                    var i = have
                    while i < lpiTargetSamples {
                        extended.append(contentsOf: data[(i % have) * sampleBytes..<((i % have) + 1) * sampleBytes])
                        i += 1
                    }
                    data = extended
                    Diag.log("移植：LPI 采样点 \(have) → \(lpiTargetSamples)"
                             + "（60Hz × \(String(format: "%.2f", secs))s）")
                }
            }

            // 1.5) still-image-time 的 sample 内容必须重建，不能照搬样本
            //
            // 真机基准（iPhone15,4 / iOS 27.2 自己拍的实况）实测，这条 sample 是 89 字节、2 个 atom：
            //    atom key=1  len=1   0xFF（-1，只是「这里有静帧」的标记）
            //    atom key=2  len=72  3×3 **单位矩阵**
            //
            // 内置样本那份是 105 字节、3 个 atom，其中矩阵带剧烈的透视分量：
            //    [1.000556, -0.000724, -1.193191,
            //      0.001964,  1.000590, -3.896847,
            //      0.000001,  0.000001,  0.998850]
            // 那是别的 App 给「做过透视校正的照片」用的。我们的照片是直接从视频里取的帧，
            // 本来就该是单位变换。照搬这组数会让 iOS 对我们的照片再做一次不该有的透视变换，
            // 照片和视频帧对不上 → 封面被判不合法 → 壁纸按钮永远是灰的。
            //
            // 用户手动「照片 → 编辑 → 拖动视频轨换封面」之所以立刻能设壁纸，
            // 就是因为 Photos 重写了这个矩阵。这里我们直接按真机写单位矩阵。
            if key == "still-image-time" {
                data = MetaTrakPorter.canonicalStillSample
            }

            mdat2.append(contentsOf: data)

            var t = Array(sData[tk.off..<(tk.off + tk.size)])
            let base = tk.off

            // 1) tkhd track_ID 换成本文件里唯一的值（2/3）
            let tid: UInt32 = key == "live-photo-info" ? 2 : 3
            if let tkhd = BoxKit.find(sData, tk, ["tkhd"]) {
                let p = BoxKit.payload(tkhd) - base
                let ver = t[p]
                BoxKit.put32(&t, p + (ver == 0 ? 12 : 20), tid)
            }

            // 2) stco / co64 指向 mdat2
            // LPI 已重建为单 chunk（stsc 只有一条），stco 必须同步成 entry_count=1、
            // 只写第一个偏移；否则多出来的旧条目指向旧 mdat，AVFoundation 读 LPI 会错位。
            if let stbl = BoxKit.find(sData, tk, ["mdia", "minf", "stbl"]) {
                if coKind == "stco", let b = BoxKit.child(sData, stbl, "stco") {
                    let p = BoxKit.payload(b) - base
                    if key == "live-photo-info", let first = newOffs.first {
                        BoxKit.put32(&t, p + 4, 1)
                        BoxKit.put32(&t, p + 8, UInt32(first))
                    } else {
                        for (i, o) in newOffs.enumerated() { BoxKit.put32(&t, p + 8 + i * 4, UInt32(o)) }
                    }
                } else if let b = BoxKit.child(sData, stbl, "co64") {
                    let p = BoxKit.payload(b) - base
                    if key == "live-photo-info", let first = newOffs.first {
                        BoxKit.put64(&t, p + 8, UInt64(first))
                    } else {
                        for (i, o) in newOffs.enumerated() { BoxKit.put64(&t, p + 8 + i * 8, UInt64(o)) }
                    }
                }
            }

            // 2.2) still-image-time 的 stsz 声明尺寸要跟着 sample 内容改成 89
            if key == "still-image-time",
               let stsz = BoxKit.find(sData, tk, ["mdia", "minf", "stbl", "stsz"]) {
                let p = BoxKit.payload(stsz) - base
                let fixed = Int(BoxKit.u32(t, p + 4))
                let old = fixed != 0 ? fixed : Int(BoxKit.u32(t, p + 12))
                let newSize = UInt32(MetaTrakPorter.canonicalStillSample.count)
                if fixed != 0 {
                    BoxKit.put32(&t, p + 4, newSize)
                } else {
                    BoxKit.put32(&t, p + 12, newSize)
                }
                Diag.log("移植：still-image-time sample \(old) → \(newSize) 字节（换成单位矩阵版）")
            }

            // 2.5) live-photo-info 轨按真机基准完整重建
            //
            // 真机自拍（p0066）与两个第三方可用产物（p0061/p0065）的 LPI 轨全是：
            //   mdhd timescale=60000，stts (n,1000) 即 60Hz，duration=n×1000
            //   stsz fixed=144 count=n，stsc [(1,n,1)]（单 chunk），stco 单点
            // 内置样本却是 600 时基、8 段 stts、6 段 stsc —— 三个能用样本没一个这样。
            // 这是「换封面后 Photos 重写」的关键动作之一，壁纸引擎很可能强依赖 60000。
            if key == "live-photo-info" {
                let LPI_TS = 60_000
                let n = lpiTargetSamples
                if let mdhd = BoxKit.find(sData, tk, ["mdia", "mdhd"]) {
                    let p = BoxKit.payload(mdhd) - base
                    let ver = t[p]
                    if ver == 0 {
                        let oldTs = Int(BoxKit.u32(t, p + 12))
                        BoxKit.put32(&t, p + 12, UInt32(LPI_TS))
                        BoxKit.put32(&t, p + 16, UInt32(n * 1000))
                        Diag.log("移植：LPI 时基 \(oldTs) → \(LPI_TS) · duration=\(n * 1000)（\(n) sample 60Hz）")
                    }
                }
                // stts → 单一 (n, 1000)
                if let stts = BoxKit.find(sData, tk, ["mdia", "minf", "stbl", "stts"]) {
                    let p = BoxKit.payload(stts) - base
                    BoxKit.put32(&t, p + 4, 1)
                    BoxKit.put32(&t, p + 8, UInt32(n))
                    BoxKit.put32(&t, p + 12, 1000)
                }
                // stsz → fixed=144, count=n
                if let stsz = BoxKit.find(sData, tk, ["mdia", "minf", "stbl", "stsz"]) {
                    let p = BoxKit.payload(stsz) - base
                    BoxKit.put32(&t, p + 4, 144)
                    BoxKit.put32(&t, p + 8, UInt32(n))
                }
                // stsc → 单一 (1, n, 1)：所有采样点在一个 chunk 里
                if let stsc = BoxKit.find(sData, tk, ["mdia", "minf", "stbl", "stsc"]) {
                    let p = BoxKit.payload(stsc) - base
                    BoxKit.put32(&t, p + 4, 1)
                    BoxKit.put32(&t, p + 8, 1)
                    BoxKit.put32(&t, p + 12, UInt32(n))
                    BoxKit.put32(&t, p + 16, 1)
                }
            }

            // 3) elst 时长对齐视频：empty edit 超出视频长度会让静帧时刻落空
            if let el = BoxKit.find(sData, tk, ["edts", "elst"]) {
                let p = BoxKit.payload(el) - base
                let ver = t[p]
                let cnt = Int(BoxKit.u32(t, p + 4))
                let esz = ver == 0 ? 12 : 20
                for i in 0..<cnt {
                    let q = p + 8 + i * esz
                    if ver == 0 {
                        let seg = Int(BoxKit.u32(t, q))
                        let mt = Int(BoxKit.i32(t, q + 4))
                        if mt == -1 {
                            // empty edit 就是静帧时刻本身。照抄样本的 920 而不按目标
                            // 视频重算，静帧会落在两帧之间 → 壁纸引擎找不到静帧 → 按钮变灰。
                            let v = (key == "still-image-time" && stillInMovieTs > 0)
                                ? stillInMovieTs
                                : max(1, min(seg, durTicks * movieTs / 600 / 2))
                            BoxKit.put32(&t, q, UInt32(v))
                        } else if seg > 10 {
                            BoxKit.put32(&t, q, UInt32(min(seg, durTicks * movieTs / 600)))
                        }
                    } else {
                        let seg = Int(BoxKit.u64(t, q))
                        // v1 的 media_time 是有符号 64 位，-1 表示 empty edit。
                        // 直接 Int(u64) 遇到 0xFFFF... 会溢出崩溃，必须走 bitPattern。
                        let mt = Int(Int64(bitPattern: BoxKit.u64(t, q + 8)))
                        if mt == -1 {
                            let v = (key == "still-image-time" && stillInMovieTs > 0)
                                ? stillInMovieTs
                                : max(1, min(seg, durTicks * movieTs / 600 / 2))
                            BoxKit.put64(&t, q, UInt64(v))
                        } else if seg > 10 {
                            BoxKit.put64(&t, q, UInt64(min(seg, durTicks * movieTs / 600)))
                        }
                    }
                }
            }

            rebuilt[key] = t
        }

        // ---- mvhd：duration 取最长轨，next_track_ID 抬到 4（vide + 2 条元数据轨）
        var mvh = Array(vMoovData[mvhd.off..<(mvhd.off + mvhd.size)])
        let mv = mvh[8]
        let tsOff = 8 + (mv == 0 ? 12 : 20)
        let durOff = 8 + (mv == 0 ? 16 : 24)
        let mts = Int(BoxKit.u32(mvh, tsOff))
        let longest = (mts == 600 || mts == 0) ? durTicks : durTicks * mts / 600
        if mv == 0 {
            BoxKit.put32(&mvh, durOff, UInt32(longest))
            BoxKit.put32(&mvh, 8 + 96, 4)
        } else {
            BoxKit.put64(&mvh, durOff, UInt64(longest))
            BoxKit.put32(&mvh, 8 + 104, 4)
        }

        // ---- 拼 moov：mvhd · 视频轨 · 2 条元数据轨 · 原 meta
        var payload: [UInt8] = []
        payload.append(contentsOf: mvh)
        payload.append(contentsOf: vMoovData[vTrak.off..<(vTrak.off + vTrak.size)])
        for k in donorOrder {
            if let t = rebuilt[k] { payload.append(contentsOf: t) }
        }
        for m in metas {
            payload.append(contentsOf: vMoovData[m.off..<(m.off + m.size)])
        }
        let newMoov = BoxKit.make("moov", payload)
        let mdat2Box = mdat2.isEmpty ? [] : BoxKit.make("mdat", mdat2)

        // ---- 写新文件：原前半段原样抄过去 → mdat2 → 新 moov
        let tmpURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent(videoURL.lastPathComponent + ".ported")
        try? FileManager.default.removeItem(at: tmpURL)
        guard FileManager.default.createFile(atPath: tmpURL.path, contents: nil) else {
            throw PortError.msg("无法创建移植临时文件")
        }
        let wh = try FileHandle(forWritingTo: tmpURL)
        let rh = try FileHandle(forReadingFrom: videoURL)
        defer { try? wh.close(); try? rh.close() }

        var remain = prefixEnd
        rh.seek(toFileOffset: 0)
        while remain > 0 {
            let n = min(remain, 4 << 20)
            let chunk = rh.readData(ofLength: n)
            if chunk.isEmpty { break }
            wh.write(chunk)
            remain -= chunk.count
        }
        if !mdat2Box.isEmpty { wh.write(Data(mdat2Box)) }
        wh.write(Data(newMoov))
        try wh.close()
        try rh.close()

        _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: tmpURL)

        var rep = Report()
        rep.tracks = ["vide"] + donorOrder
        rep.sampleBytes = mdat2.count
        rep.outputBytes = prefixEnd + mdat2Box.count + newMoov.count
        rep.stillSeconds = Double(stillPts) / 600.0
        return rep
    }

    // MARK: - 小工具

    static func handler(_ d: [UInt8], _ trak: BoxKit.Box) -> String {
        guard let h = BoxKit.find(d, trak, ["mdia", "hdlr"]) else { return "?" }
        return BoxKit.fourCC(d, BoxKit.payload(h) + 8)
    }

    static func keyTag(_ d: [UInt8], _ trak: BoxKit.Box) -> String {
        guard let stsd = BoxKit.find(d, trak, ["mdia", "minf", "stbl", "stsd"]) else { return "?" }
        let p = BoxKit.payload(stsd)
        let esz = Int(BoxKit.u32(d, p + 8))
        let lo = p + 8, hi = min(d.count, lo + max(0, esz))
        guard lo < hi else { return "?" }
        let s = String(decoding: d[lo..<hi], as: UTF8.self)
        for k in donorOrder where s.contains(k) { return k }
        return "?"
    }

    static func mdhdInfo(_ d: [UInt8], _ trak: BoxKit.Box) -> (ts: Int, dur: Int) {
        guard let b = BoxKit.find(d, trak, ["mdia", "mdhd"]) else { return (600, 0) }
        let p = BoxKit.payload(b)
        let v = d[p]
        if v == 0 {
            return (Int(BoxKit.u32(d, p + 12)), Int(BoxKit.u32(d, p + 16)))
        }
        return (Int(BoxKit.u32(d, p + 20)), Int(BoxKit.u64(d, p + 24)))
    }

    /// 把 600 时基的目标时刻对齐到「不晚于它的最后一帧起点」，并夹在时长内。
    /// 封面搜索专用：系统对 still-image-time 的判据是必须落在真实帧边界上。
    static func alignToFrame(_ target600: Int,
                             _ d: [UInt8], _ trak: BoxKit.Box,
                             timescale: Int,
                             fallback: Int,
                             durationTicks: Int) -> Int {
        guard let stts = BoxKit.find(d, trak, ["mdia", "minf", "stbl", "stts"]) else {
            return min(max(0, target600), max(0, durationTicks - 1))
        }
        let p = BoxKit.payload(stts)
        let n = Int(BoxKit.u32(d, p + 4))
        guard n > 0 else { return target600 }
        let ts = timescale > 0 ? timescale : 600
        // 目标从 600 时基换算回视频轨时基
        let targetMedia = ts == 600 ? target600 : target600 * ts / 600
        var pts = 0
        var best = 0
        for i in 0..<n {
            let cnt = Int(BoxKit.u32(d, p + 8 + i * 8))
            let delta = Int(BoxKit.u32(d, p + 12 + i * 8))
            if delta <= 0 { continue }
            if pts > targetMedia { break }
            let k = min(cnt - 1, max(0, (targetMedia - pts) / delta))
            best = pts + k * delta
            pts += cnt * delta
        }
        let clampedMedia = min(best, max(0, durationTicks * ts / 600 - 1))
        return ts == 600 ? clampedMedia : clampedMedia * 600 / ts
    }

    /// 静帧落在视频正中间那一帧的精确 PTS（600 时基）。
    ///
    /// 这是整套移植里最容易错、也最要命的一处：
    /// 真机样本 90 帧 / 30fps，still-image-time 的 elst empty edit = 920 ticks，
    /// 而 920 恰好等于「第 46 帧（total/2 + 1）的 PTS」—— 一一对应。
    /// v3.1 直接照抄了样本的 920，遇到 24fps/60fps 的视频静帧就掉进两帧之间，
    /// 壁纸引擎取不到封面帧，实况按钮于是变灰。
    /// 老板真机验证：进照片编辑重选一次封面就能用 —— 那正是 Photos 重算了这个时刻。
    /// 静帧时刻：**固定 0.5 秒**，并对齐到不晚于该时刻的最后一帧起点。
    ///
    /// 依据（三个「确定能设壁纸」的样本一致）：
    ///   p0066  真机自拍    1.000s → 0.5s
    ///   p0061  第三方 App  0.983s → 0.5s
    ///   p0065  第三方 App  0.767s → 0.5s
    /// 返回值的单位是**视频轨的 timescale**。视频短于 0.6 秒时退到中间。
    static func stillPointPts(_ d: [UInt8],
                              _ trak: BoxKit.Box,
                              timescale: Int) -> (pts: Int, frames: Int) {
        guard let stts = BoxKit.find(d, trak, ["mdia", "minf", "stbl", "stts"]) else { return (0, 0) }
        let p = BoxKit.payload(stts)
        let n = Int(BoxKit.u32(d, p + 4))
        guard n > 0 else { return (0, 0) }
        var entries: [(cnt: Int, delta: Int)] = []
        for i in 0..<n {
            entries.append((Int(BoxKit.u32(d, p + 8 + i * 8)),
                            Int(BoxKit.u32(d, p + 12 + i * 8))))
        }
        let total = entries.reduce(0) { $0 + $1.cnt }
        guard total > 0 else { return (0, 0) }
        let ts = timescale > 0 ? timescale : 600
        let totalTicks = entries.reduce(0) { $0 + $1.cnt * $1.delta }
        let durationSec = Double(totalTicks) / Double(ts)
        let targetSec = durationSec < 0.6 ? durationSec / 2 : 0.5
        let target = Int(targetSec * Double(ts))

        // 找不晚于 target 的最后一帧起点
        var pts = 0
        var best = 0
        for e in entries {
            if e.delta <= 0 { pts += e.cnt * max(0, e.delta); continue }
            if pts > target { break }
            let k = min(e.cnt - 1, (target - pts) / e.delta)
            best = pts + k * e.delta
            pts += e.cnt * e.delta
        }
        return (best, total)
    }

    /// 保留旧实现（历史版本用「总帧数/2+1」的中间帧），当前不再调用。
    static func midPointPts(_ d: [UInt8], _ trak: BoxKit.Box) -> (pts: Int, frames: Int) {
        guard let stts = BoxKit.find(d, trak, ["mdia", "minf", "stbl", "stts"]) else { return (0, 0) }
        let p = BoxKit.payload(stts)
        let n = Int(BoxKit.u32(d, p + 4))
        var entries: [(cnt: Int, delta: Int)] = []
        for i in 0..<n {
            entries.append((Int(BoxKit.u32(d, p + 8 + i * 8)),
                            Int(BoxKit.u32(d, p + 12 + i * 8))))
        }
        let total = entries.reduce(0) { $0 + $1.cnt }
        guard total > 0 else { return (0, 0) }
        let target = total / 2 + 1
        var pts = 0
        var idx = 0
        for e in entries {
            if idx + e.cnt > target {
                return (pts + (target - idx) * e.delta, total)
            }
            pts += e.cnt * e.delta
            idx += e.cnt
        }
        return (pts, total)
    }

    struct Chunk { var off: Int; var sizes: [Int] }

    static func chunks(_ d: [UInt8], _ trak: BoxKit.Box) -> ([Chunk], String) {
        guard let stsz = BoxKit.find(d, trak, ["mdia", "minf", "stbl", "stsz"]),
              let stsc = BoxKit.find(d, trak, ["mdia", "minf", "stbl", "stsc"]) else {
            return ([], "stco")
        }
        var p = BoxKit.payload(stsz)
        let fixed = Int(BoxKit.u32(d, p + 4))
        let cnt = Int(BoxKit.u32(d, p + 8))
        var sizes: [Int] = []
        if fixed != 0 {
            sizes = Array(repeating: fixed, count: cnt)
        } else {
            let q = p + 12
            for i in 0..<cnt where q + i * 4 + 4 <= d.count {
                sizes.append(Int(BoxKit.u32(d, q + i * 4)))
            }
        }

        var offs: [Int] = []
        var kind = "stco"
        if let stco = BoxKit.find(d, trak, ["mdia", "minf", "stbl", "stco"]) {
            p = BoxKit.payload(stco)
            let n = Int(BoxKit.u32(d, p + 4))
            for i in 0..<n { offs.append(Int(BoxKit.u32(d, p + 8 + i * 4))) }
        } else if let co64 = BoxKit.find(d, trak, ["mdia", "minf", "stbl", "co64"]) {
            kind = "co64"
            p = BoxKit.payload(co64)
            let n = Int(BoxKit.u32(d, p + 4))
            for i in 0..<n { offs.append(Int(BoxKit.u64(d, p + 8 + i * 8))) }
        }

        p = BoxKit.payload(stsc)
        let ns = Int(BoxKit.u32(d, p + 4))
        var tri: [(first: Int, spc: Int)] = []
        for i in 0..<ns {
            let q = p + 8 + i * 12
            tri.append((Int(BoxKit.u32(d, q)), Int(BoxKit.u32(d, q + 4))))
        }

        var out: [Chunk] = []
        var si = 0
        for ci in 1...max(1, offs.count) where !offs.isEmpty {
            var spc = 1
            for t in tri where ci >= t.first { spc = t.spc }
            let hi = min(sizes.count, si + spc)
            let grp = si < hi ? Array(sizes[si..<hi]) : []
            out.append(Chunk(off: offs[ci - 1], sizes: grp))
            si += spc
        }
        return (out, kind)
    }

    static func scanTop(_ url: URL) throws -> ([BoxKit.Box], Int) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let fsize = Int(try fh.seekToEnd())
        var out: [BoxKit.Box] = []
        var p = 0
        while p + 8 <= fsize {
            fh.seek(toFileOffset: UInt64(p))
            let head = fh.readData(ofLength: 16)
            guard head.count >= 8 else { break }
            let h = [UInt8](head)
            var sz = Int(BoxKit.u32(h, 0))
            var hdr = 8
            if sz == 1 {
                guard h.count >= 16 else { break }
                sz = Int(BoxKit.u64(h, 8)); hdr = 16
            } else if sz == 0 {
                sz = fsize - p
            }
            if sz < hdr || p + sz > fsize { break }
            out.append(BoxKit.Box(type: BoxKit.fourCC(h, 4), off: p, size: sz, hdr: hdr))
            p += sz
        }
        return (out, fsize)
    }

    static func readRange(_ url: URL, offset: Int, length: Int) throws -> [UInt8] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        fh.seek(toFileOffset: UInt64(offset))
        let d = fh.readData(ofLength: length)
        return [UInt8](d)
    }
}
