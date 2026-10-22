#!/usr/bin/env python3
"""Kismet (UE4 Blueprint) bytecode disassembler - pure Python, UE 4.20."""
import struct, sys
sys.path.insert(0, '/tmp/mods')
from uasset import Asset

EX = {
0x00:'LocalVariable',0x01:'InstanceVariable',0x02:'DefaultVariable',0x04:'Return',
0x06:'Jump',0x07:'JumpIfNot',0x09:'Assert',0x0B:'Nothing',0x0F:'Let',
0x12:'ClassContext',0x13:'MetaCast',0x14:'LetBool',0x15:'EndParmValue',
0x16:'EndFunctionParms',0x17:'Self',0x18:'Skip',0x19:'Context',
0x1A:'Context_FailSilent',0x1B:'VirtualFunction',0x1C:'FinalFunction',
0x1D:'IntConst',0x1E:'FloatConst',0x1F:'StringConst',0x20:'ObjectConst',
0x21:'NameConst',0x22:'RotationConst',0x23:'VectorConst',0x24:'ByteConst',
0x25:'IntZero',0x26:'IntOne',0x27:'True',0x28:'False',0x29:'TextConst',
0x2A:'NoObject',0x2B:'TransformConst',0x2C:'IntConstByte',0x2D:'NoInterface',
0x2E:'DynamicCast',0x2F:'StructConst',0x30:'EndStructConst',0x31:'SetArray',
0x32:'EndArray',0x33:'PropertyConst',0x34:'UnicodeStringConst',0x35:'Int64Const',
0x36:'UInt64Const',0x38:'PrimitiveCast',0x39:'SetSet',0x3A:'EndSet',
0x3B:'SetMap',0x3C:'EndMap',0x3D:'SetConst',0x3E:'EndSetConst',0x3F:'MapConst',
0x40:'EndMapConst',0x42:'StructMemberContext',0x43:'LetMulticastDelegate',
0x44:'LetDelegate',0x45:'LocalVirtualFunction',0x46:'LocalFinalFunction',
0x48:'LocalOutVariable',0x4A:'DeprecatedOp4A',0x4B:'InstanceDelegate',
0x4C:'PushExecutionFlow',0x4D:'PopExecutionFlow',0x4E:'ComputedJump',
0x4F:'PopExecutionFlowIfNot',0x50:'Breakpoint',0x51:'InterfaceContext',
0x52:'ObjToInterfaceCast',0x53:'EndOfScript',0x54:'CrossInterfaceCast',
0x55:'InterfaceToObjCast',0x5A:'WireTracepoint',0x5B:'SkipOffsetConst',
0x5C:'AddMulticastDelegate',0x5D:'ClearMulticastDelegate',0x5E:'Tracepoint',
0x5F:'LetObj',0x60:'LetWeakObjPtr',0x61:'BindDelegate',
0x62:'RemoveMulticastDelegate',0x63:'CallMulticastDelegate',
0x64:'LetValueOnPersistentFrame',0x65:'ArrayConst',0x66:'EndArrayConst',
0x67:'SoftObjectConst',0x68:'CallMath',0x69:'SwitchValue',
0x6A:'InstrumentationEvent',0x6B:'ArrayGetByRef',0x6C:'ClassSparseDataVariable',
0x6D:'FieldPathConst',
}


class Dis:
    def __init__(self, asset, code):
        self.a = asset
        self.c = code
        self.out = []          # (file_off, rt_off, depth, text)
        self.delta = 0         # runtime offsets are bigger: ptr 4B file -> 8B runtime

    # --- primitive readers -------------------------------------------------
    def u8(self, o):  return self.c[o], o + 1
    def i32(self, o): return struct.unpack_from('<i', self.c, o)[0], o + 4
    def u32(self, o): return struct.unpack_from('<I', self.c, o)[0], o + 4
    def u16(self, o): return struct.unpack_from('<H', self.c, o)[0], o + 2
    def f32(self, o): return struct.unpack_from('<f', self.c, o)[0], o + 4
    def i64(self, o): return struct.unpack_from('<q', self.c, o)[0], o + 8

    def ptr(self, o):
        """Object ref inside bytecode is an FPackageIndex (int32) in the file."""
        v = struct.unpack_from('<i', self.c, o)[0]
        self.delta += 4
        return v, o + 4

    def name(self, o):
        idx = struct.unpack_from('<i', self.c, o)[0]
        num = struct.unpack_from('<i', self.c, o + 4)[0]
        s = self.a.names[idx] if 0 <= idx < len(self.a.names) else '<n%d>' % idx
        return (s + ('_%d' % (num - 1) if num else '')), o + 8

    def objname(self, v):
        """Resolve an 8-byte bytecode object pointer to a readable name."""
        if v == 0:
            return 'None'
        i = v
        if i < 0:
            k = -i - 1
            if k < len(self.a.imports):
                return self.a.imports[k][3]
        else:
            k = i - 1
            if k < len(self.a.exports):
                return self.a.exports[k]['name']
        return 'obj#%d' % v

    def cstr(self, o):
        s = b''
        while self.c[o] != 0:
            s += bytes([self.c[o]]); o += 1
        return s.decode('utf-8', 'replace'), o + 1

    # --- expression walker -------------------------------------------------
    def expr(self, o, d=0):
        start = o
        self._rt = start + self.delta
        op, o = self.u8(o)
        n = EX.get(op, 'UNK_%02X' % op)
        emit = n

        if n in ('LocalVariable', 'InstanceVariable', 'DefaultVariable',
                 'LocalOutVariable', 'ClassSparseDataVariable'):
            v, o = self.ptr(o); emit = f'{n} {self.objname(v)}'
        elif n == 'Return':
            self.rec(start, d, n); return self.expr(o, d + 1)
        elif n in ('Jump',):
            t, o = self.u32(o); emit = f'Jump -> {t}'
        elif n == 'JumpIfNot':
            t, o = self.u32(o); emit = f'{n} -> {t}'
            self.rec(start, d, emit); return self.expr(o, d + 1)
        elif n == 'PopExecutionFlowIfNot':
            self.rec(start, d, n); return self.expr(o, d + 1)
        elif n == 'PushExecutionFlow':
            t, o = self.u32(o); emit = f'PushExecutionFlow {t}'
        elif n == 'ComputedJump':
            self.rec(start, d, n); return self.expr(o, d + 1)
        elif n in ('Let', 'LetObj', 'LetBool', 'LetWeakObjPtr', 'LetDelegate',
                   'LetMulticastDelegate', 'ArrayGetByRef'):
            if n == 'Let':
                v, o = self.ptr(o)
            self.rec(start, d, n)
            o = self.expr(o, d + 1)
            return self.expr(o, d + 1)
        elif n == 'LetValueOnPersistentFrame':
            v, o = self.ptr(o)
            self.rec(start, d, f'{n} {self.objname(v)}')
            return self.expr(o, d + 1)
        elif n in ('Context', 'Context_FailSilent', 'ClassContext'):
            self.rec(start, d, n)
            o = self.expr(o, d + 1)              # target
            _sk, o = self.u32(o)                 # skip bytes
            _rv, o = self.ptr(o)                 # rvalue property
            return self.expr(o, d + 1)           # member expression
        elif n in ('VirtualFunction', 'LocalVirtualFunction'):
            fn, o = self.name(o); emit = f'{n} {fn}'
            self.rec(start, d, emit)
            return self.parms(o, d + 1)
        elif n in ('FinalFunction', 'LocalFinalFunction', 'CallMath'):
            v, o = self.ptr(o); emit = f'{n} {self.objname(v)}'
            self.rec(start, d, emit)
            return self.parms(o, d + 1)
        elif n == 'CallMulticastDelegate':
            v, o = self.ptr(o)
            self.rec(start, d, f'{n} {self.objname(v)}')
            o = self.expr(o, d + 1)
            return self.parms(o, d + 1)
        elif n == 'IntConst':
            v, o = self.i32(o); emit = f'IntConst {v}'
        elif n == 'FloatConst':
            v, o = self.f32(o); emit = f'FloatConst {v}'
        elif n == 'ByteConst' or n == 'IntConstByte':
            v, o = self.u8(o); emit = f'{n} {v}'
        elif n == 'ObjectConst':
            v, o = self.ptr(o); emit = f'ObjectConst {self.objname(v)}'
        elif n == 'NameConst':
            v, o = self.name(o); emit = f'NameConst "{v}"'
        elif n == 'StringConst':
            v, o = self.cstr(o); emit = f'StringConst "{v}"'
        elif n == 'UnicodeStringConst':
            s = ''
            while True:
                ch, o = self.u16(o)
                if ch == 0: break
                s += chr(ch)
            emit = f'UnicodeStringConst "{s}"'
        elif n == 'SoftObjectConst':
            self.rec(start, d, n); return self.expr(o, d + 1)
        elif n in ('True', 'False', 'Nothing', 'IntZero', 'IntOne', 'Self',
                   'NoObject', 'NoInterface', 'EndOfScript', 'EndFunctionParms',
                   'EndStructConst', 'EndArray', 'EndArrayConst', 'EndSet',
                   'EndMap', 'EndSetConst', 'EndMapConst', 'PopExecutionFlow',
                   'EndParmValue', 'Breakpoint', 'WireTracepoint', 'Tracepoint',
                   'DeprecatedOp4A'):
            pass
        elif n == 'VectorConst':
            x, o = self.f32(o); y, o = self.f32(o); z, o = self.f32(o)
            emit = f'VectorConst ({x:.1f},{y:.1f},{z:.1f})'
        elif n == 'RotationConst':
            a_, o = self.f32(o); b_, o = self.f32(o); c_, o = self.f32(o)
            emit = f'RotationConst ({a_:.1f},{b_:.1f},{c_:.1f})'
        elif n == 'TransformConst':
            o += 40; emit = 'TransformConst'
        elif n == 'Int64Const' or n == 'UInt64Const':
            v, o = self.i64(o); emit = f'{n} {v}'
        elif n == 'StructConst':
            v, o = self.ptr(o); _sz, o = self.i32(o)
            self.rec(start, d, f'StructConst {self.objname(v)}')
            while self.c[o] != 0x30:
                o = self.expr(o, d + 1)
            return o + 1
        elif n == 'SetArray':
            self.rec(start, d, n)
            o = self.expr(o, d + 1)
            while self.c[o] != 0x32:
                o = self.expr(o, d + 1)
            return o + 1
        elif n == 'ArrayConst':
            v, o = self.ptr(o); _n, o = self.i32(o)
            self.rec(start, d, 'ArrayConst')
            while self.c[o] != 0x66:
                o = self.expr(o, d + 1)
            return o + 1
        elif n in ('DynamicCast', 'MetaCast', 'ObjToInterfaceCast',
                   'CrossInterfaceCast', 'InterfaceToObjCast'):
            v, o = self.ptr(o)
            self.rec(start, d, f'{n} -> {self.objname(v)}')
            return self.expr(o, d + 1)
        elif n == 'PrimitiveCast':
            t, o = self.u8(o)
            self.rec(start, d, f'PrimitiveCast t{t}')
            return self.expr(o, d + 1)
        elif n == 'StructMemberContext':
            v, o = self.ptr(o)
            self.rec(start, d, f'{n} {self.objname(v)}')
            return self.expr(o, d + 1)
        elif n in ('AddMulticastDelegate', 'RemoveMulticastDelegate',
                   'BindDelegate', 'ClearMulticastDelegate'):
            if n == 'BindDelegate':
                nm, o = self.name(o); emit = f'{n} "{nm}"'
            self.rec(start, d, emit)
            o = self.expr(o, d + 1)
            if n != 'ClearMulticastDelegate':
                o = self.expr(o, d + 1)
            return o
        elif n == 'InstanceDelegate':
            nm, o = self.name(o); emit = f'{n} "{nm}"'
        elif n == 'Skip':
            t, o = self.u32(o)
            self.rec(start, d, f'Skip -> {t}')
            return self.expr(o, d + 1)
        elif n == 'Assert':
            ln, o = self.u16(o); _dbg, o = self.u8(o)
            self.rec(start, d, f'Assert line {ln}')
            return self.expr(o, d + 1)
        elif n == 'SwitchValue':
            cnt, o = self.u16(o); end, o = self.u32(o)
            self.rec(start, d, f'SwitchValue {cnt} cases -> end {end}')
            o = self.expr(o, d + 1)
            for _ in range(cnt):
                o = self.expr(o, d + 2)
                _nx, o = self.u32(o)
                o = self.expr(o, d + 2)
            return self.expr(o, d + 1)
        elif n == 'InstrumentationEvent':
            t, o = self.u8(o)
            if t == 1:
                _nm, o = self.name(o)
            emit = f'{n} t{t}'
        elif n == 'TextConst':
            t, o = self.u8(o)
            self.rec(start, d, f'TextConst t{t}')
            if t == 0:
                return o
            if t == 2:
                for _ in range(3):
                    o = self.expr(o, d + 1)
                return o
            return self.expr(o, d + 1)
        elif n == 'SkipOffsetConst':
            v, o = self.u32(o); emit = f'SkipOffsetConst {v}'
        elif n == 'InterfaceContext':
            self.rec(start, d, n); return self.expr(o, d + 1)
        elif n == 'PropertyConst' or n == 'FieldPathConst':
            v, o = self.ptr(o); emit = f'{n} {self.objname(v)}'
        else:
            self.rec(start, d, f'!! {emit} (unhandled)')
            raise ValueError('unhandled op %02X at %d' % (op, start))

        self.rec(start, d, emit)
        return o

    def parms(self, o, d):
        while self.c[o] != 0x16:
            o = self.expr(o, d)
        self.rec(o, d, 'EndFunctionParms')
        return o + 1

    def rec(self, off, d, text):
        self.out.append((off, off + self.delta, d, text))

    def run(self, limit=None):
        o = 0
        while o < len(self.c):
            if limit and len(self.out) > limit:
                break
            try:
                o = self.expr(o, 0)
            except (ValueError, IndexError, struct.error) as e:
                self.rec(o, 0, f'*** STOP: {e}')
                break
        return self.out


def find_code(asset, data, exp):
    """Locate the bytecode inside a Function export by trial."""
    blob = data[exp['off']:exp['off'] + exp['size']]
    best = (None, None, None, None)
    for hdr in range(12, min(len(blob), 400)):
        bsz = struct.unpack_from('<i', blob, hdr - 8)[0]
        ssz = struct.unpack_from('<i', blob, hdr - 4)[0]
        if ssz <= 0 or hdr + ssz > len(blob):
            continue
        code = blob[hdr:hdr + ssz]
        if code[-1] == 0x53 and bsz >= ssz:
            if best[0] is None or ssz > best[3]:
                best = (code, hdr, bsz, ssz)
    return best
