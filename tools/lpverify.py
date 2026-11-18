"""校验 lpbox 移植产物：轨数 / 元数据 sample 字节 / 视频 mdat 完整性"""
import sys, struct
sys.path.insert(0, 'tools')
from movdump import bparse, children, walk, payload

def top(d):
    return bparse(d, 0, len(d))

def moov(d):
    return [b for b in top(d) if b[0] == 'moov'][0]

def traks(d):
    return [b for b in children(d, moov(d)) if b[0] == 'trak']

def handler(d, tk):
    b = walk(d, tk, ['mdia', 'hdlr'])
    return d[payload(b)+8:payload(b)+12].decode('latin1')

def allsamples(d, trak):
    stsz = walk(d, trak, ['mdia', 'minf', 'stbl', 'stsz']); P = payload(stsz)
    fixed, cnt = struct.unpack('>II', d[P+4:P+12])
    sizes = [fixed]*cnt if fixed else list(struct.unpack('>%dI' % cnt, d[P+12:P+12+4*cnt]))
    stco = walk(d, trak, ['mdia', 'minf', 'stbl', 'stco'])
    co64 = walk(d, trak, ['mdia', 'minf', 'stbl', 'co64'])
    if stco:
        P = payload(stco); n = struct.unpack('>I', d[P+4:P+8])[0]
        offs = list(struct.unpack('>%dI' % n, d[P+8:P+8+4*n]))
    else:
        P = payload(co64); n = struct.unpack('>I', d[P+4:P+8])[0]
        offs = list(struct.unpack('>%dQ' % n, d[P+8:P+8+8*n]))
    stsc = walk(d, trak, ['mdia', 'minf', 'stbl', 'stsc']); P = payload(stsc)
    nn = struct.unpack('>I', d[P+4:P+8])[0]
    tri = [struct.unpack('>III', d[P+8+i*12:P+8+i*12+12]) for i in range(nn)]
    out = []; si = 0
    for ci in range(1, len(offs)+1):
        spc = 1
        for fc, sp, _ in tri:
            if ci >= fc: spc = sp
        p = offs[ci-1]
        for _ in range(spc):
            sz = sizes[si]; out.append(d[p:p+sz]); p += sz; si += 1
    return out

def keytag(d, tk):
    stsd = walk(d, tk, ['mdia', 'minf', 'stbl', 'stsd']); P = payload(stsd)
    esz = struct.unpack('>I', d[P+8:P+12])[0]
    blob = d[P+8:P+8+esz]
    for k in ('live-photo-info', 'still-image-time', 'video-orientation'):
        if k.encode() in blob: return k
    return '?'

def report(sample_path, out_path, video_src=None):
    S = open(sample_path, 'rb').read()
    T = open(out_path, 'rb').read()
    st = traks(S); tt = traks(T)
    print(f'样本轨数 {len(st)} · 产物轨数 {len(tt)}')
    for tk in tt:
        print('   ', handler(T, tk), keytag(T, tk) if handler(T, tk) == 'meta' else '')
    # 按 key 对齐比对
    smap = {}
    for tk in st:
        if handler(S, tk) == 'meta':
            smap[keytag(S, tk)] = tk
    ok = True
    for tk in tt:
        if handler(T, tk) != 'meta': continue
        k = keytag(T, tk)
        a = allsamples(S, smap[k]); b = allsamples(T, tk)
        same = len(a) == len(b) and all(x == y for x, y in zip(a, b))
        ok = ok and same
        print(f'   {k}: {len(a)} vs {len(b)} sample · 字节一致={same}')
    # moov/meta 的 content.identifier
    m = walk(T, moov(T), ['meta'])
    if m:
        ilst = walk(T, m, ['ilst']); P = payload(ilst)
        raw = T[P:P+200]
        i = raw.find(b'\x00\x00\x00\x36')
        uuid = raw[i+8+8:i+8+8+36].decode('latin1')
        print('   content.identifier =', uuid)
    if video_src:
        V = open(video_src, 'rb').read()
        vmdat = [b for b in top(V) if b[0] == 'mdat'][0]
        tmdat = [b for b in top(T) if b[0] == 'mdat'][0]
        same = V[vmdat[1]+vmdat[3]:vmdat[1]+vmdat[2]] == T[tmdat[1]+tmdat[3]:tmdat[1]+tmdat[2]]
        print('   视频 mdat 字节一致 =', same, f'({vmdat[2]} vs {tmdat[2]})')
        ok = ok and same
    print('结论:', '通过' if ok else '不通过')

if __name__ == '__main__':
    report(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
