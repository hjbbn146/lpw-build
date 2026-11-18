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

    // MARK: - 入口

    /// 原地把 videoURL 重写成带完整实况元数据轨的版本（成功后原文件被覆盖）
    @discardableResult
    static func port(videoURL: URL, sampleURL: URL) throws -> Report {
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
        let midRaw = midPointPts(vMoovData, vTrak)
        let midPts = (vTimescale == 600 || vTimescale == 0)
            ? midRaw.pts : midRaw.pts * 600 / vTimescale
        Diag.log("移植：视频 \(midRaw.frames) 帧 · 静帧取第 \(midRaw.frames/2 + 1) 帧 PTS=\(midPts)")

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
            if let stbl = BoxKit.find(sData, tk, ["mdia", "minf", "stbl"]) {
                if coKind == "stco", let b = BoxKit.child(sData, stbl, "stco") {
                    let p = BoxKit.payload(b) - base
                    for (i, o) in newOffs.enumerated() { BoxKit.put32(&t, p + 8 + i * 4, UInt32(o)) }
                } else if let b = BoxKit.child(sData, stbl, "co64") {
                    let p = BoxKit.payload(b) - base
                    for (i, o) in newOffs.enumerated() { BoxKit.put64(&t, p + 8 + i * 8, UInt64(o)) }
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
                            let v = (key == "still-image-time" && midPts > 0)
                                ? midPts
                                : max(1, min(seg, durTicks / 2))
                            BoxKit.put32(&t, q, UInt32(v))
                        } else if seg > 10 {
                            BoxKit.put32(&t, q, UInt32(min(seg, durTicks)))
                        }
                    } else {
                        let seg = Int(BoxKit.u64(t, q))
                        // v1 的 media_time 是有符号 64 位，-1 表示 empty edit。
                        // 直接 Int(u64) 遇到 0xFFFF... 会溢出崩溃，必须走 bitPattern。
                        let mt = Int(Int64(bitPattern: BoxKit.u64(t, q + 8)))
                        if mt == -1 {
                            let v = (key == "still-image-time" && midPts > 0)
                                ? midPts
                                : max(1, min(seg, durTicks / 2))
                            BoxKit.put64(&t, q, UInt64(v))
                        } else if seg > 10 {
                            BoxKit.put64(&t, q, UInt64(min(seg, durTicks)))
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
        rep.stillSeconds = Double(midPts) / 600.0
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

    /// 静帧落在视频正中间那一帧的精确 PTS（600 时基）。
    ///
    /// 这是整套移植里最容易错、也最要命的一处：
    /// 真机样本 90 帧 / 30fps，still-image-time 的 elst empty edit = 920 ticks，
    /// 而 920 恰好等于「第 46 帧（total/2 + 1）的 PTS」—— 一一对应。
    /// v3.1 直接照抄了样本的 920，遇到 24fps/60fps 的视频静帧就掉进两帧之间，
    /// 壁纸引擎取不到封面帧，实况按钮于是变灰。
    /// 老板真机验证：进照片编辑重选一次封面就能用 —— 那正是 Photos 重算了这个时刻。
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
