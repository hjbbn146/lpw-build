"""无损实况 · MOV box 级元数据轨移植（原型验证用）

把「真机原生实况 MOV」里的 3 条元数据轨（live-photo-info / still-image-time /
video-orientation）整条搬到「App 直通产出的 MOV」里，其余字节一个不动。

移植后目标文件的轨结构应当与真机样本完全一致：
    trak1 vide(hvc1) + trak2 meta(live-photo-info)
    + trak3 meta(still-image-time) + trak4 meta(video-orientation) + moov/meta
"""
import sys, struct, os

# ---------------------------------------------------------------- box 工具

def parse(d, off=0, end=None):
    end = len(d) if end is None else end
    out = []
    while off + 8 <= end:
        sz, typ = struct.unpack('>I4s', d[off:off+8])
        hdr = 8
        if sz == 1:
            sz = struct.unpack('>Q', d[off+8:off+16])[0]; hdr = 16
        elif sz == 0:
            sz = end - off
        if sz < hdr or off + sz > end:
            break
        out.append((typ.decode('latin1'), off, sz, hdr))
        off += sz
    return out

def kids(d, box):
    typ, o, s, h = box
    start = o + h
    if typ == 'meta':
        start += 4
    elif typ == 'stsd':
        start += 8
    return parse(d, start, o + s)

def child(d, box, name):
    for c in kids(d, box):
        if c[0] == name:
            return c
    return None

def path(d, box, names):
    cur = box
    for n in names:
        cur = child(d, cur, n)
        if cur is None:
            return None
    return cur

def pay(box):
    return box[1] + box[3]

def mk(typ, payload):
    return struct.pack('>I4s', len(payload) + 8, typ.encode('latin1')) + payload

def raw(d, box):
    return d[box[1]:box[1] + box[2]]

# ---------------------------------------------------------------- 参数读取

def mdhd_info(d, trak):
    b = path(d, trak, ['mdia', 'mdhd'])
    P = pay(b); v = d[P]
    if v == 0:
        return struct.unpack('>I', d[P+12:P+16])[0], struct.unpack('>I', d[P+16:P+20])[0], P, v
    return struct.unpack('>I', d[P+20:P+24])[0], struct.unpack('>Q', d[P+24:P+32])[0], P, v

def tkhd_trackid_pos(d, trak):
    b = path(d, trak, ['tkhd'])
    P = pay(b); v = d[P]
    return P + (12 if v == 0 else 20)

def handler(d, trak):
    b = path(d, trak, ['mdia', 'hdlr'])
    return d[pay(b)+8:pay(b)+12].decode('latin1', 'replace')

def chunk_map(d, trak):
    """→ [(chunk_index, [sample_size, ...]), ...] ，按文件内原始顺序"""
    stbl = path(d, trak, ['mdia', 'minf', 'stbl'])
    stsz = path(d, trak, ['mdia', 'minf', 'stbl', 'stsz'])
    P = pay(stsz)
    fixed, cnt = struct.unpack('>II', d[P+4:P+12])
    sizes = [fixed] * cnt if fixed else list(struct.unpack('>%dI' % cnt, d[P+12:P+12+4*cnt]))

    stco = child(d, stbl, 'stco')
    co64 = child(d, stbl, 'co64')
    if stco:
        P = pay(stco); n = struct.unpack('>I', d[P+4:P+8])[0]
        offs = list(struct.unpack('>%dI' % n, d[P+8:P+8+4*n]))
        kind = 'stco'
    else:
        P = pay(co64); n = struct.unpack('>I', d[P+4:P+8])[0]
        offs = list(struct.unpack('>%dQ' % n, d[P+8:P+8+8*n]))
        kind = 'co64'

    stsc = path(d, trak, ['mdia', 'minf', 'stbl', 'stsc'])
    P = pay(stsc); n = struct.unpack('>I', d[P+4:P+8])[0]
    triples = [struct.unpack('>III', d[P+8+i*12:P+8+i*12+12]) for i in range(n)]

    out = []
    si = 0
    for ci in range(1, n_chunks_ok := len(offs) + 1):
        spc = 1
        for fc, sp, _sd in triples:
            if ci >= fc:
                spc = sp
        grp = sizes[si:si+spc]
        out.append((ci, offs[ci-1], grp))
        si += spc
    if si != cnt:
        print(f'   !! 警告：stsc 展开得到 {si} 个 sample，stsz 声明 {cnt}')
    return out, kind

# ---------------------------------------------------------------- 主流程

META_KEYS = ('live-photo-info', 'still-image-time', 'video-orientation')

def keytag(d, trak):
    """从 stsd 的 mebx 里读 key 名，用于识别这条元数据轨是什么"""
    stsd = path(d, trak, ['mdia', 'minf', 'stbl', 'stsd'])
    P = pay(stsd)
    esz = struct.unpack('>I', d[P+8:P+12])[0]
    blob = d[P+8:P+8+esz]
    for k in META_KEYS:
        if k.encode() in blob:
            return k
    return 'unknown'

def transcode(video_mov, sample_mov, out_mov, verbose=True):
    V = open(video_mov, 'rb').read()
    S = open(sample_mov, 'rb').read()

    vtop = parse(V)
    smoov = [b for b in parse(S) if b[0] == 'moov'][0]
    straks = [b for b in kids(S, smoov) if b[0] == 'trak']

    # 样本里挑出 3 条元数据轨
    donor = []
    for tk in straks:
        if handler(S, tk) != 'meta':
            continue
        k = keytag(S, tk)
        donor.append((k, tk))
    if verbose:
        print('donor 轨：', [(k, tk[2]) for k, tk in donor])
    order = ['live-photo-info', 'still-image-time', 'video-orientation']
    donor.sort(key=lambda kv: order.index(kv[0]) if kv[0] in order else 99)

    # ---- 视频侧 moov
    vmoov = [b for b in vtop if b[0] == 'moov'][0]
    vkids = kids(V, vmoov)
    mvhd = [b for b in vkids if b[0] == 'mvhd'][0]
    meta = [b for b in vkids if b[0] == 'meta']
    vtrak = [b for b in vkids if b[0] == 'trak' and handler(V, b) == 'vide']
    if not vtrak:
        raise SystemExit('视频侧没有 vide 轨')
    vtrak = vtrak[0]
    if verbose:
        print('视频侧 moov 子项：', [(b[0], b[2]) for b in vkids])

    # ---- mdat 位置（视频数据保持原位，stco 无需改）
    # 输出布局：ftyp + wide + mdat(原样) + mdat2(新) + moov(重建)
    head = b''.join(raw(V, b) for b in vtop if b[0] in ('ftyp', 'wide', 'mdat'))
    md2_base = len(head) + 8          # +8 为 mdat2 头
    # ---- 视频时长（先算，元数据轨的 elst 要按它裁剪）
    vts, vdur, vP, vver = mdhd_info(V, vtrak)
    dur_ticks = vdur if vts == 600 else vdur * 600 // vts
    if verbose:
        print(f'head={len(head)} mdat2 payload 起点={md2_base}')
        print(f'视频轨 mdhd ts={vts} dur={vdur} → 归一 600 时基 {dur_ticks}')
    md2 = bytearray()
    rebuilt = []
    for k, tk in donor:
        chunks, co_kind = chunk_map(S, tk)
        new_offs = []
        data = bytearray()
        for ci, old_off, sizes in chunks:
            new_offs.append(md2_base + len(md2) + len(data))
            p = old_off
            for sz in sizes:
                data += S[p:p+sz]
                p += sz
        if verbose:
            print(f'  {k}: {len(chunks)} chunk / {sum(len(c[2]) for c in chunks)} sample / {len(data)} B')
        blob = bytes(data)
        md2 += blob
        # 重建 trak 原始字节
        t = bytearray(raw(S, tk))
        base = tk[1]
        # 1) tkhd track_ID
        pos = tkhd_trackid_pos(S, tk) - base
        tid_new = (2 if k == 'live-photo-info' else 3 if k == 'still-image-time' else 4)
        t[pos:pos+4] = struct.pack('>I', tid_new)
        # 2) stco / co64 换新偏移
        stbl = path(S, tk, ['mdia', 'minf', 'stbl'])
        if co_kind == 'stco':
            b = child(S, stbl, 'stco'); P = pay(b) - base
            for i, o in enumerate(new_offs):
                t[P+8+i*4:P+8+i*4+4] = struct.pack('>I', o)
        else:
            b = child(S, stbl, 'co64'); P = pay(b) - base
            for i, o in enumerate(new_offs):
                t[P+8+i*8:P+8+i*8+8] = struct.pack('>Q', o)
        # 3) elst 对齐视频时长：empty edit 超出视频长度会让静帧时刻落空
        el = path(S, tk, ['edts', 'elst'])
        if el:
            P = pay(el) - base
            ver = t[P]
            cnt = struct.unpack('>I', t[P+4:P+8])[0]
            esz = 20 if ver else 12
            for i in range(cnt):
                q = P + 8 + i * esz
                if ver == 0:
                    seg = struct.unpack('>I', t[q:q+4])[0]
                    mt = struct.unpack('>i', t[q+4:q+8])[0]
                    if mt == -1:
                        seg = max(1, min(seg, dur_ticks // 2))
                        t[q:q+4] = struct.pack('>I', seg)
                    elif seg > 10:
                        t[q:q+4] = struct.pack('>I', min(seg, dur_ticks))
                else:
                    seg = struct.unpack('>Q', t[q:q+8])[0]
                    mt = struct.unpack('>q', t[q+8:q+16])[0]
                    if mt == -1:
                        seg = max(1, min(seg, dur_ticks // 2))
                        t[q:q+8] = struct.pack('>Q', seg)
                    elif seg > 10:
                        t[q:q+8] = struct.pack('>Q', min(seg, dur_ticks))
        rebuilt.append((k, bytes(t)))

    # ---- 时长已在上面算出（elst 已在循环内按 dur_ticks 裁剪）
    if verbose:
        pass

    # ---- 修 mvhd：duration 取各轨最大值，next_track_ID 放到 5
    mvh = bytearray(raw(V, mvhd))
    mv = mvh[8]                       # version
    dur_off = 8 + (16 if mv == 0 else 24)
    ts_off = 8 + (12 if mv == 0 else 20)
    mts = struct.unpack('>I', mvh[ts_off:ts_off+4])[0] or 600
    longest = dur_ticks if mts == 600 else dur_ticks * mts // 600
    if mv == 0:
        mvh[dur_off:dur_off+4] = struct.pack('>I', longest)
        mvh[8+96:8+100] = struct.pack('>I', 5)
    else:
        mvh[dur_off:dur_off+8] = struct.pack('>Q', longest)
        mvh[8+104:8+108] = struct.pack('>I', 5)
    if verbose:
        print(f'mvhd 修正：duration={longest} next_track_ID=5 (原 duration 见下)')

    # ---- 组装 moov
    payload = bytearray()
    payload += bytes(mvh)
    payload += raw(V, vtrak)
    for k, t in rebuilt:
        payload += t
    for b in meta:
        payload += raw(V, b)
    moov = mk('moov', bytes(payload))

    # ---- 组装文件
    mdat2 = mk('mdat', bytes(md2)) if md2 else b''
    out = head + mdat2 + moov
    open(out_mov, 'wb').write(out)
    if verbose:
        print(f'写出 {out_mov} · {len(out)} B（原 {len(V)} B）')
    return out

if __name__ == '__main__':
    transcode(sys.argv[1], sys.argv[2], sys.argv[3])
