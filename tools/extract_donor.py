#!/usr/bin/env python3
"""从真机实况 MOV 提取「纯元数据空壳」：只留 LPI + SIT 两条 meta 轨及其 sample，
不含任何视频/音频画面数据。用于替换内置移植供体，保证 stsd 与 sample 自洽。

用法: extract_donor.py <源.MOV> <输出.mov>
"""
import struct
import sys
import pathlib


def parse(d, off=0, end=None):
    end = len(d) if end is None else end
    out = []
    while off + 8 <= end:
        sz, typ = struct.unpack('>I4s', d[off:off + 8])
        hdr = 8
        if sz == 1:
            sz = struct.unpack('>Q', d[off + 8:off + 16])[0]
            hdr = 16
        elif sz == 0:
            sz = end - off
        if sz < hdr or off + sz > end:
            break
        out.append((typ.decode('latin1'), off, sz, hdr))
        off += sz
    return out


def kids(d, b):
    t, o, s, h = b
    st = o + h
    if t == 'meta':
        st += 4
    elif t == 'stsd':
        st += 8
    return parse(d, st, o + s)


def child(d, b, n):
    for c in kids(d, b):
        if c[0] == n:
            return c
    return None


def path(d, b, ns):
    cur = b
    for n in ns:
        cur = child(d, cur, n)
        if not cur:
            return None
    return cur


def chunk_list(d, tk):
    """返回 [(off, size)]，按 chunk 顺序。"""
    stsz = path(d, tk, ['mdia', 'minf', 'stbl', 'stsz'])
    Q = stsz[1] + stsz[3]
    ss = struct.unpack('>I', d[Q + 4:Q + 8])[0]
    cnt = struct.unpack('>I', d[Q + 8:Q + 12])[0]
    stco = path(d, tk, ['mdia', 'minf', 'stbl', 'stco'])
    R = stco[1] + stco[3]
    nc = struct.unpack('>I', d[R + 4:R + 8])[0]
    offs = list(struct.unpack('>%dI' % nc, d[R + 8:R + 8 + 4 * nc]))
    stsc = path(d, tk, ['mdia', 'minf', 'stbl', 'stsc'])
    S = stsc[1] + stsc[3]
    ns = struct.unpack('>I', d[S + 4:S + 8])[0]
    ent = [struct.unpack('>III', d[S + 8 + i * 12:S + 20 + i * 12]) for i in range(ns)]
    out = []
    for i, off in enumerate(offs):
        per = 1
        for (fc, spc, sdi) in ent:
            if fc <= i + 1:
                per = spc
        out.append((off, per * ss))
    return out


def rewrite_stco(trak_bytes, base_off_in_trak, new_offsets):
    """在 trak 字节里改 stco/co64 的偏移表。返回新字节。"""
    b = bytearray(trak_bytes)

    def find_box(buf, start, end, name):
        # buf 起点可以是 trak 本身；逐层下钻
        for t, o, s, h in parse(buf, start, end):
            if t == name:
                return o, s, h
            if t in ('trak', 'mdia', 'minf', 'stbl', 'edts'):
                # trak 顶层需从 box 内容起点开始（o+h）
                r = find_box(buf, o + h, o + s, name)
                if r:
                    return r
        return None

    for typ, width in (('stco', 4), ('co64', 8)):
        r = find_box(b, 0, len(b), typ)
        if r:
            o, s, h = r
            n = struct.unpack('>I', b[o + h + 4:o + h + 8])[0]
            for i in range(min(n, len(new_offsets))):
                p = o + h + 8 + i * width
                if width == 4:
                    struct.pack_into('>I', b, p, new_offsets[i])
                else:
                    struct.pack_into('>Q', b, p, new_offsets[i])
            return bytes(b)
    return bytes(b)


def main():
    src = pathlib.Path(sys.argv[1])
    dst = pathlib.Path(sys.argv[2])
    d = src.read_bytes()
    top = parse(d)
    ftyp = next(t for t in top if t[0] == 'ftyp')
    moov = next(t for t in top if t[0] == 'moov')
    ftyp_bytes = d[ftyp[1]:ftyp[1] + ftyp[2]]
    mvhd = child(d, moov, 'mvhd')

    lpi = sit = None
    for tk in kids(d, moov):
        if tk[0] != 'trak':
            continue
        stsd = path(d, tk, ['mdia', 'minf', 'stbl', 'stsd'])
        P = stsd[1] + stsd[3]
        esz = struct.unpack('>I', d[P + 8:P + 12])[0]
        sample = d[P + 8:P + 8 + esz]
        if b'still-image-time' in sample:
            sit = tk
        elif b'live-photo-info' in sample:
            lpi = tk
    if not lpi or not sit:
        sys.exit("源文件缺 LPI 或 SIT 轨")

    # 按 LPI 在前、SIT 在后的顺序收集 sample
    order = [('LPI', lpi), ('SIT', sit)]
    body = bytearray()
    layouts = {}
    for name, tk in order:
        cl = chunk_list(d, tk)
        offs = []
        for (o, sz) in cl:
            offs.append(len(body))
            body += d[o:o + sz]
        layouts[name] = offs

    # 目标布局: ftyp + mdat(body) + moov
    mdat_header = 8 + len(body)
    data_start = len(ftyp_bytes) + 8
    abs_offsets = {k: [data_start + x for x in v] for k, v in layouts.items()}

    trak_bytes = {}
    for name, tk in order:
        raw = d[tk[1]:tk[1] + tk[2]]
        trak_bytes[name] = rewrite_stco(raw, 0, abs_offsets[name])

    new_moov_children = bytearray()
    new_moov_children += d[mvhd[1]:mvhd[1] + mvhd[2]]
    for name, _ in order:
        new_moov_children += trak_bytes[name]

    moov_size = 8 + len(new_moov_children)
    out = bytearray()
    out += ftyp_bytes
    out += struct.pack('>I4s', mdat_header, b'mdat')
    out += body
    out += struct.pack('>I4s', moov_size, b'moov')
    out += new_moov_children
    dst.write_bytes(bytes(out))

    print(f"OK {dst} {len(out)} bytes  (ftyp {len(ftyp_bytes)} + mdat {mdat_header} + moov {moov_size})")
    for name in ('LPI', 'SIT'):
        print(f"  {name} chunks={len(layouts[name])} samples_bytes={sum(1 for _ in layouts[name])} offsets={abs_offsets[name][:4]}")


if __name__ == '__main__':
    main()
