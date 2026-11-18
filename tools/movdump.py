import sys, struct, re

def bparse(buf, off, end):
    out = []
    while off + 8 <= end:
        sz, typ = struct.unpack('>I4s', buf[off:off+8])
        hdr = 8
        if sz == 1:
            sz = struct.unpack('>Q', buf[off+8:off+16])[0]; hdr = 16
        elif sz == 0:
            sz = end - off
        if sz < hdr or off + sz > end:
            break
        out.append((typ.decode('latin1'), off, sz, hdr))
        off += sz
    return out

def children(buf, box):
    typ, o, s, h = box
    if typ == 'stsd':
        return bparse(buf, o + h + 8, o + s)
    if typ == 'meta':
        # QuickTime 的 meta 是 fullbox（header 后还有 4 字节 version/flags），
        # 但 AVAssetWriter 写出来的 meta 省略了这 4 字节。两种都试一遍。
        r = bparse(buf, o + h, o + s)
        if r and all(ch.isalnum() or ch in ' -_' for ch in r[0][0]):
            return r
        return bparse(buf, o + h + 4, o + s)
    return bparse(buf, o + h, o + s)

def walk(buf, box, names):
    cur = box
    for nm in names:
        nxt = None
        for c in children(buf, cur):
            if c[0] == nm:
                nxt = c; break
        if nxt is None:
            return None
        cur = nxt
    return cur

def payload(box, extra=0):
    return box[1] + box[3] + extra

def dump(fn, show_meta=True):
    d = open(fn, 'rb').read()
    print('FILE', fn, 'size', len(d))
    top = bparse(d, 0, len(d))
    print('top:', [(t, s) for t, o, s, h in top])
    moov = [x for x in top if x[0] == 'moov']
    if not moov:
        print('NO MOOV'); return None
    mv = moov[0]
    r = walk(d, mv, ['mvhd'])
    if r:
        P = payload(r)
        v = d[P]
        if v == 0:
            ts = struct.unpack('>I', d[P+12:P+16])[0]; du = struct.unpack('>I', d[P+16:P+20])[0]
        else:
            ts = struct.unpack('>I', d[P+20:P+24])[0]; du = struct.unpack('>Q', d[P+24:P+32])[0]
        print(f'mvhd ver={v} timescale={ts} dur={du} ({du/ts if ts else 0:.3f}s)')
    traks = [c for c in children(d, mv) if c[0] == 'trak']
    print('TRAK COUNT', len(traks))
    for i, tk in enumerate(traks):
        hdl = walk(d, tk, ['mdia', 'hdlr'])
        handler = d[payload(hdl)+8:payload(hdl)+12].decode('latin1', 'replace') if hdl else '?'
        mdhd = walk(d, tk, ['mdia', 'mdhd'])
        mt = md = 0
        if mdhd:
            P = payload(mdhd); v = d[P]
            if v == 0:
                mt = struct.unpack('>I', d[P+12:P+16])[0]; md = struct.unpack('>I', d[P+16:P+20])[0]
            else:
                mt = struct.unpack('>I', d[P+20:P+24])[0]; md = struct.unpack('>Q', d[P+24:P+32])[0]
        print(f'--- trak{i+1} handler={handler!r} timescale={mt} dur={md} ({md/mt if mt else 0:.3f}s)')
        stsd = walk(d, tk, ['mdia', 'minf', 'stbl', 'stsd'])
        if stsd:
            P = payload(stsd)
            n = struct.unpack('>I', d[P+4:P+8])[0]
            esz, etyp = struct.unpack('>I4s', d[P+8:P+16])
            ename = etyp.decode('latin1')
            print(f'    stsd n={n} entry={ename} esz={esz}')
            blob = d[P+8:P+8+esz]
            strs = [s.decode('latin1', 'replace') for s in re.findall(rb'[ -~]{3,}', blob)]
            print(f'    strings({len(strs)}): {strs[:30]}')
            if ename in ('hvc1', 'hev1', 'avc1'):
                W, H = struct.unpack('>HH', blob[32:36])
                print(f'    visual w={W} h={H}')
        for nm in ('stsz', 'stco', 'co64', 'stts', 'stsc'):
            r2 = walk(d, tk, ['mdia', 'minf', 'stbl', nm])
            if not r2: continue
            P = payload(r2)
            if nm == 'stsz':
                ss, cnt = struct.unpack('>II', d[P+4:P+12])
                print(f'    stsz sample_size={ss} count={cnt}')
            elif nm == 'stco':
                nc = struct.unpack('>I', d[P+4:P+8])[0]
                print(f'    stco n={nc} offsets={struct.unpack(">%dI"%nc, d[P+8:P+8+4*nc])[:8] if nc else ()}')
            elif nm == 'co64':
                nc = struct.unpack('>I', d[P+4:P+8])[0]
                print(f'    co64 n={nc} offsets={struct.unpack(">%dQ"%nc, d[P+8:P+8+8*nc])[:8] if nc else ()}')
            elif nm == 'stts':
                nc = struct.unpack('>I', d[P+4:P+8])[0]
                print(f'    stts n={nc} pairs={struct.unpack(">%dI"%(nc*2), d[P+8:P+8+8*nc])[:10] if nc else ()}')
            elif nm == 'stsc':
                nc = struct.unpack('>I', d[P+4:P+8])[0]
                print(f'    stsc n={nc} {struct.unpack(">%dI"%(nc*3), d[P+8:P+8+12*nc])[:12] if nc else ()}')
    if show_meta:
        mt_ = walk(d, mv, ['meta'])
        if mt_:
            print('MOOV META size', mt_[1])
            keys = walk(d, mt_, ['keys'])
            if keys:
                P = payload(keys)
                cnt = struct.unpack('>I', d[P+4:P+8])[0]
                print('   keys count', cnt)
                p = P + 8
                for k in range(cnt):
                    ksz = struct.unpack('>I', d[p:p+4])[0]
                    ns = d[p+4:p+ksz][4:].rstrip(b'\x00').decode('latin1', 'replace')
                    print(f'     key[{k}] size={ksz} {ns!r}')
                    p += ksz
            ilst = walk(d, mt_, ['ilst'])
            if ilst:
                P = payload(ilst)
                print('   ilst size', ilst[2])
                for t, o, s, h in bparse(d, P, ilst[1] + ilst[2]):
                    print(f'     ilst item size={s} raw={d[o:o+s][:48].hex()}')
            for t, o, s, h in children(d, mt_):
                print('   meta child:', t, s, d[o+8:o+min(s,24)].hex())
    return None

if __name__ == '__main__':
    for f in sys.argv[1:]:
        dump(f); print()
