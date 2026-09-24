#!/usr/bin/env python3
"""
asm6502.py — minimal two-pass 6502 assembler for CBM prg Studio syntax.

Purpose: verify assembly listings before they go to the real IDE, and emit
a .prg or a BASIC DATA loader. Catches undefined labels, branch out of
range, illegal addressing modes, and reports the assembled byte size.

Usage:
  python3 asm6502.py source.asm                 # assemble, print listing
  python3 asm6502.py source.asm -o out.prg      # write .prg (load addr + bytes)
  python3 asm6502.py source.asm --data [--sys]  # BASIC DATA loader (lowercase)
  python3 asm6502.py source.asm --listing       # address / bytes / source

Supported syntax (prg Studio subset):
  *=$C000              origin (required before first instruction)
  label                label in column 1, no colon
  @local               local label (scoped to previous non-local label)
  name = expr          equate
  byte 1,$02,%11,'c'   data bytes; text in "..." or '...' also allowed here
  word $1234,label     little-endian words
  text "hello"         PETSCII string (ASCII lower -> PETSCII $41-5A)
  ; comment            to end of line
  #<expr  #>expr       low / high byte immediates
  Expressions: + - * / ( ) with labels, *, $hex, %bin, decimal, 'c'
"""
import sys, re, argparse

# ---------------------------------------------------------------- opcode table
# mode keys: imp acc imm zp zpx zpy abs abx aby ind izx izy rel
OPS = {
 'adc':{'imm':0x69,'zp':0x65,'zpx':0x75,'abs':0x6D,'abx':0x7D,'aby':0x79,'izx':0x61,'izy':0x71},
 'and':{'imm':0x29,'zp':0x25,'zpx':0x35,'abs':0x2D,'abx':0x3D,'aby':0x39,'izx':0x21,'izy':0x31},
 'asl':{'acc':0x0A,'zp':0x06,'zpx':0x16,'abs':0x0E,'abx':0x1E},
 'bcc':{'rel':0x90},'bcs':{'rel':0xB0},'beq':{'rel':0xF0},'bmi':{'rel':0x30},
 'bne':{'rel':0xD0},'bpl':{'rel':0x10},'bvc':{'rel':0x50},'bvs':{'rel':0x70},
 'bit':{'zp':0x24,'abs':0x2C},
 'brk':{'imp':0x00},'clc':{'imp':0x18},'cld':{'imp':0xD8},'cli':{'imp':0x58},'clv':{'imp':0xB8},
 'cmp':{'imm':0xC9,'zp':0xC5,'zpx':0xD5,'abs':0xCD,'abx':0xDD,'aby':0xD9,'izx':0xC1,'izy':0xD1},
 'cpx':{'imm':0xE0,'zp':0xE4,'abs':0xEC},
 'cpy':{'imm':0xC0,'zp':0xC4,'abs':0xCC},
 'dec':{'zp':0xC6,'zpx':0xD6,'abs':0xCE,'abx':0xDE},
 'dex':{'imp':0xCA},'dey':{'imp':0x88},
 'eor':{'imm':0x49,'zp':0x45,'zpx':0x55,'abs':0x4D,'abx':0x5D,'aby':0x59,'izx':0x41,'izy':0x51},
 'inc':{'zp':0xE6,'zpx':0xF6,'abs':0xEE,'abx':0xFE},
 'inx':{'imp':0xE8},'iny':{'imp':0xC8},
 'jmp':{'abs':0x4C,'ind':0x6C},
 'jsr':{'abs':0x20},
 'lda':{'imm':0xA9,'zp':0xA5,'zpx':0xB5,'abs':0xAD,'abx':0xBD,'aby':0xB9,'izx':0xA1,'izy':0xB1},
 'ldx':{'imm':0xA2,'zp':0xA6,'zpy':0xB6,'abs':0xAE,'aby':0xBE},
 'ldy':{'imm':0xA0,'zp':0xA4,'zpx':0xB4,'abs':0xAC,'abx':0xBC},
 'lsr':{'acc':0x4A,'zp':0x46,'zpx':0x56,'abs':0x4E,'abx':0x5E},
 'nop':{'imp':0xEA},
 'ora':{'imm':0x09,'zp':0x05,'zpx':0x15,'abs':0x0D,'abx':0x1D,'aby':0x19,'izx':0x01,'izy':0x11},
 'pha':{'imp':0x48},'php':{'imp':0x08},'pla':{'imp':0x68},'plp':{'imp':0x28},
 'rol':{'acc':0x2A,'zp':0x26,'zpx':0x36,'abs':0x2E,'abx':0x3E},
 'ror':{'acc':0x6A,'zp':0x66,'zpx':0x76,'abs':0x6E,'abx':0x7E},
 'rti':{'imp':0x40},'rts':{'imp':0x60},
 'sbc':{'imm':0xE9,'zp':0xE5,'zpx':0xF5,'abs':0xED,'abx':0xFD,'aby':0xF9,'izx':0xE1,'izy':0xF1},
 'sec':{'imp':0x38},'sed':{'imp':0xF8},'sei':{'imp':0x78},
 'sta':{'zp':0x85,'zpx':0x95,'abs':0x8D,'abx':0x9D,'aby':0x99,'izx':0x81,'izy':0x91},
 'stx':{'zp':0x86,'zpy':0x96,'abs':0x8E},
 'sty':{'zp':0x84,'zpx':0x94,'abs':0x8C},
 'tax':{'imp':0xAA},'tay':{'imp':0xA8},'tsx':{'imp':0xBA},'txa':{'imp':0x8A},'txs':{'imp':0x9A},'tya':{'imp':0x98},
}
# stable "illegal" opcodes (NMOS 6510). Enabled with --illegal. Names follow
# Groepaz's No More Secrets; asr is accepted as an alias of alr.
ILLEGAL = {
 'lax':{'zp':0xA7,'zpy':0xB7,'abs':0xAF,'aby':0xBF,'izx':0xA3,'izy':0xB3},
 'sax':{'zp':0x87,'zpy':0x97,'abs':0x8F,'izx':0x83},
 'sbx':{'imm':0xCB},'axs':{'imm':0xCB},
 'dcp':{'zp':0xC7,'zpx':0xD7,'abs':0xCF,'abx':0xDF,'aby':0xDB,'izx':0xC3,'izy':0xD3},
 'isc':{'zp':0xE7,'zpx':0xF7,'abs':0xEF,'abx':0xFF,'aby':0xFB,'izx':0xE3,'izy':0xF3},
 'slo':{'zp':0x07,'zpx':0x17,'abs':0x0F,'abx':0x1F,'aby':0x1B,'izx':0x03,'izy':0x13},
 'rla':{'zp':0x27,'zpx':0x37,'abs':0x2F,'abx':0x3F,'aby':0x3B,'izx':0x23,'izy':0x33},
 'sre':{'zp':0x47,'zpx':0x57,'abs':0x4F,'abx':0x5F,'aby':0x5B,'izx':0x43,'izy':0x53},
 'rra':{'zp':0x67,'zpx':0x77,'abs':0x6F,'abx':0x7F,'aby':0x7B,'izx':0x63,'izy':0x73},
 'anc':{'imm':0x0B},'alr':{'imm':0x4B},'asr':{'imm':0x4B},'arr':{'imm':0x6B},
 'dop':{'imp':0x80},'top':{'imp':0x0C},     # 1 byte each: the *next* 1 / 2 bytes are the skipped operand
}
SIZE = {'imp':1,'acc':1,'imm':2,'zp':2,'zpx':2,'zpy':2,'abs':3,'abx':3,'aby':3,'ind':3,'izx':2,'izy':2,'rel':2}
DIRECTIVES = {'byte','.byte','word','.word','text','.text','watch','incbin','incasm','operator'}
COL1_DIRECTIVES = {'incbin','incasm','incdir','include','align','watch','byte','word','text','operator'}

class AsmError(Exception): pass

def petscii(ch):
    o = ord(ch)
    if 97 <= o <= 122: return o - 32        # a-z -> $41-$5A (unshifted)
    if 65 <= o <= 90:  return o + 128       # A-Z -> $C1-$DA (shifted)
    return o & 0xFF

# ---------------------------------------------------------------- expressions
TOK = re.compile(r"\s*(?:(\$[0-9A-Fa-f]+)|(%[01]+)|(\d+)|('(.)')|([A-Za-z_@.][A-Za-z0-9_@.]*)|(\*)|([()+\-*/]))")

class Expr:
    def __init__(self, text, labels, pc, scope):
        self.s = text; self.labels = labels; self.pc = pc; self.scope = scope
        self.pos = 0; self.undefined = False
    def tok(self):
        m = TOK.match(self.s, self.pos)
        if not m or self.pos >= len(self.s):
            return None
        self.pos = m.end()
        return m
    def peek(self):
        p = self.pos; m = self.tok(); self.pos = p; return m
    def parse(self):
        v = self.expr()
        rest = self.s[self.pos:].strip()
        if rest: raise AsmError(f"unexpected '{rest}' in expression '{self.s}'")
        return v
    def expr(self):
        v = self.term()
        while True:
            m = self.peek()
            if m and m.group(8) in ('+','-'):
                self.tok()
                r = self.term()
                v = v + r if m.group(8) == '+' else v - r
            else: return v
    def term(self):
        v = self.factor()
        while True:
            m = self.peek()
            opch = m.group(8) if m and m.group(8) in ('*','/') else ('*' if m and m.group(7) else None)
            if opch:
                self.tok()
                r = self.factor()
                v = v * r if opch == '*' else (v // r if r else 0)
            else: return v
    def factor(self):
        m = self.tok()
        if not m: raise AsmError(f"bad expression '{self.s}'")
        if m.group(1): return int(m.group(1)[1:], 16)
        if m.group(2): return int(m.group(2)[1:], 2)
        if m.group(3): return int(m.group(3))
        if m.group(4): return petscii(m.group(5))
        if m.group(6):
            name = m.group(6)
            if name.startswith('@'): name = self.scope + name
            if name in self.labels: return self.labels[name]
            self.undefined = True; return 0
        if m.group(7): return self.pc
        if m.group(8) == '(':
            v = self.expr()
            m2 = self.tok()
            if not m2 or m2.group(8) != ')': raise AsmError(f"missing ) in '{self.s}'")
            return v
        if m.group(8) == '-':
            return -self.factor()
        raise AsmError(f"bad token in '{self.s}'")

# ---------------------------------------------------------------- operand parsing
def parse_operand(op, labels, pc, scope):
    """Return (mode_candidates, value, undefined). mode_candidates is an ordered
    list; first one whose opcode exists is used."""
    op = op.strip()
    if op == '': return (['imp','acc'], 0, False)   # bare 'asl' = 'asl a'
    if op.lower() == 'a': return (['acc'], 0, False)
    lo = hi = False
    if op.startswith('#'):
        body = op[1:].strip()
        if body.startswith('<'): lo = True; body = body[1:]
        elif body.startswith('>'): hi = True; body = body[1:]
        e = Expr(body, labels, pc, scope); v = e.parse()
        if lo: v &= 0xFF
        elif hi: v = (v >> 8) & 0xFF
        return (['imm'], v & 0xFF, e.undefined)
    m = re.fullmatch(r'\((.+)\)\s*,\s*[yY]', op)
    if m:
        e = Expr(m.group(1), labels, pc, scope); return (['izy'], e.parse(), e.undefined)
    m = re.fullmatch(r'\((.+),\s*[xX]\)', op)
    if m:
        e = Expr(m.group(1), labels, pc, scope); return (['izx'], e.parse(), e.undefined)
    m = re.fullmatch(r'\((.+)\)', op)
    if m:
        e = Expr(m.group(1), labels, pc, scope); return (['ind'], e.parse(), e.undefined)
    m = re.fullmatch(r'(.+),\s*[xX]', op)
    if m:
        e = Expr(m.group(1), labels, pc, scope); v = e.parse()
        return (['zpx','abx'] if (v < 256 and not e.undefined) else ['abx'], v, e.undefined)
    m = re.fullmatch(r'(.+),\s*[yY]', op)
    if m:
        e = Expr(m.group(1), labels, pc, scope); v = e.parse()
        return (['zpy','aby'] if (v < 256 and not e.undefined) else ['aby'], v, e.undefined)
    e = Expr(op, labels, pc, scope); v = e.parse()
    return (['zp','abs','rel'] if (v < 256 and not e.undefined) else ['abs','rel'], v, e.undefined)

def split_line(raw):
    """Strip comment (respecting quotes), return (label, mnemonic, operand)."""
    out = []; q = None
    for ch in raw:
        if q:
            out.append(ch)
            if ch == q: q = None
        elif ch in ('"', "'"):
            q = ch; out.append(ch)
        elif ch == ';':
            break
        else: out.append(ch)
    line = ''.join(out).rstrip()
    if not line.strip(): return (None, None, None)
    label = None
    if not line[0].isspace():
        # column-1 token: label, equate, *=, or a directive (prg studio puts
        # incbin/incasm/etc. in column 1)
        m = re.match(r'(\*\s*=|[A-Za-z_@.][A-Za-z0-9_@.]*)(.*)$', line)
        if not m: raise AsmError(f"cannot parse line: {raw.rstrip()}")
        first, rest = m.group(1), m.group(2)
        if first.replace(' ','') == '*=':
            return (None, '*=', rest.strip())
        if re.match(r'\s*=', rest):
            return (first, '=', rest.split('=',1)[1].strip())
        if first.lower() in COL1_DIRECTIVES:
            return (None, first.lower(), rest.strip())
        label = first; line = rest
    line = line.strip()
    if not line: return (label, None, None)
    parts = line.split(None, 1)
    mnem = parts[0].lower()
    operand = parts[1].strip() if len(parts) > 1 else ''
    if mnem == 'operator':  # 'operator calc' etc. — ignore
        return (label, None, None)
    return (label, mnem, operand)

def parse_data(op, labels, pc, scope, width):
    """byte/word operand list -> list of ints, undefined flag."""
    vals = []; undef = False
    # split on commas outside quotes
    items = []; cur = ''; q = None
    for ch in op:
        if q:
            cur += ch
            if ch == q: q = None
        elif ch in ('"', "'"):
            q = ch; cur += ch
        elif ch == ',':
            items.append(cur); cur = ''
        else: cur += ch
    if cur.strip(): items.append(cur)
    for it in items:
        it = it.strip()
        if len(it) >= 2 and it[0] in ('"', "'") and it[-1] == it[0]:
            for ch in it[1:-1]: vals.append(petscii(ch))
            continue
        lo = hi = False
        if it.startswith('<'): lo = True; it = it[1:]
        elif it.startswith('>'): hi = True; it = it[1:]
        e = Expr(it, labels, pc, scope); v = e.parse(); undef |= e.undefined
        if lo: v &= 0xFF
        elif hi: v = (v >> 8) & 0xFF
        if width == 1: vals.append(v & 0xFF)
        else: vals.append(v & 0xFF); vals.append((v >> 8) & 0xFF)
    return vals, undef

# ---------------------------------------------------------------- assembler
def assemble(src, illegal=False):
    ops = dict(OPS); ops.update(ILLEGAL) if illegal else None
    lines = src.splitlines()
    labels = {}
    listing = []
    warnings = []
    for pass_no in (1, 2, 3):            # 3 passes settle zp/abs size changes
        pc = None; origin = None; out = bytearray(); scope = ''; listing = []; warnings = []
        defined = {}                     # label -> line, this pass: a label
        def define(name, n):             # given twice is an error, not a
            if name in defined and defined[name] != n:   # silent pick
                raise AsmError(f"duplicate label '{name}' (first defined at line {defined[name]})")
            defined[name] = n
        for n, raw in enumerate(lines, 1):
            try:
                label, mnem, operand = split_line(raw)
                start = pc
                if mnem == '*=':
                    e = Expr(operand, labels, pc or 0, scope); v = e.parse()
                    if origin is None: origin = v
                    elif v < pc: raise AsmError("*= moves backwards")
                    elif v > pc: out.extend(b'\x00' * (v - pc))
                    pc = v; listing.append((n, pc, b'', raw)); continue
                if mnem == '=':
                    define(label, n)
                    e = Expr(operand, labels, pc or 0, scope); labels[label] = e.parse()
                    listing.append((n, None, b'', raw)); continue
                if label:
                    if label.startswith('@'): define(scope + label, n); labels[scope + label] = pc
                    else: define(label, n); labels[label] = pc; scope = label
                if mnem is None:
                    listing.append((n, pc, b'', raw)); continue
                if pc is None: raise AsmError("no *= origin before code")
                code = bytearray()
                if mnem in ('byte', '.byte'):
                    vals, _ = parse_data(operand, labels, pc, scope, 1); code.extend(vals)
                elif mnem in ('word', '.word'):
                    vals, _ = parse_data(operand, labels, pc, scope, 2); code.extend(vals)
                elif mnem in ('text', '.text'):
                    vals, _ = parse_data(operand, labels, pc, scope, 1); code.extend(vals)
                elif mnem in ('watch', 'incbin', 'incasm', 'incdir', 'include', 'align'):
                    if mnem in ('incbin', 'incasm', 'include') and pass_no == 3:
                        sys.stderr.write(f"warning line {n}: {mnem} not supported by verifier, skipped (prg studio's incbin is for its editor files; use byte lines for raw binary)\n")
                elif mnem in ops:
                    modes, v, undef = parse_operand(operand, labels, pc, scope)
                    table = ops[mnem]
                    if 'rel' in table:
                        if undef and pass_no < 3: code.extend(b'\x00\x00')
                        else:
                            off = v - (pc + 2)
                            if pass_no == 3 and not (-128 <= off <= 127):
                                raise AsmError(f"branch out of range ({off} bytes) to ${v:04X}")
                            if pass_no == 3 and off < 0 and ((pc + 2) >> 8) != (v >> 8):
                                warnings.append(f"line {n}: backward branch to ${v:04X} crosses a page boundary (+1 cycle when taken) — a loop straddling a page")
                            code.extend([table['rel'], off & 0xFF])
                    else:
                        mode = next((m for m in modes if m in table), None)
                        if mode is None:
                            raise AsmError(f"illegal addressing mode for {mnem}: '{operand}'")
                        if SIZE[mode] == 2 and mode != 'imm' and v > 255 and not undef:
                            raise AsmError(f"{mnem} {operand}: this mode needs a zero-page address, got ${v:04X}")
                        code.append(table[mode])
                        if SIZE[mode] == 2: code.append(v & 0xFF)
                        elif SIZE[mode] == 3: code.extend([v & 0xFF, (v >> 8) & 0xFF])
                    if pass_no == 3 and undef:
                        raise AsmError(f"undefined label in '{operand}'")
                elif mnem in ILLEGAL:
                    raise AsmError(f"'{mnem}' is an illegal opcode; assemble with --illegal to allow it")
                else:
                    raise AsmError(f"unknown mnemonic or directive '{mnem}'")
                out.extend(code); listing.append((n, pc, bytes(code), raw)); pc += len(code)
            except AsmError as ex:
                if pass_no == 3 or 'unknown mnemonic' in str(ex) or 'illegal addressing' in str(ex):
                    raise AsmError(f"line {n}: {ex}\n    {raw.rstrip()}")
    if origin is None: raise AsmError("no *= origin found")
    for w in warnings: sys.stderr.write('warning ' + w + '\n')
    return origin, bytes(out), labels, listing

# ---------------------------------------------------------------- outputs
def to_prg(origin, data):
    return bytes([origin & 0xFF, origin >> 8]) + data

def to_basic_data(origin, data, sys_call=True, start_line=10):
    """Lowercase BASIC loader: reads DATA into memory, optionally SYS."""
    lines = []; ln = start_line
    lines.append(f"{ln} fori={origin}to{origin+len(data)-1}:reada:pokei,a:nexti"); ln += 10
    if sys_call:
        lines.append(f"{ln} sys{origin}"); ln += 10
    else:
        lines.append(f"{ln} print\"loaded at {origin}\""); ln += 10
    ln = 1000
    i = 0
    while i < len(data):
        chunk = []; s = f"{ln} data"
        while i < len(data):
            piece = (',' if chunk else '') + str(data[i])
            if len(s) + len(piece) > 78: break
            s += piece; chunk.append(data[i]); i += 1
        lines.append(s); ln += 10
    return '\n'.join(lines) + '\n'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('source')
    ap.add_argument('-o', '--output', help='write .prg')
    ap.add_argument('--data', action='store_true', help='emit BASIC DATA loader')
    ap.add_argument('--nosys', action='store_true', help='loader without SYS')
    ap.add_argument('--listing', action='store_true')
    ap.add_argument('--symbols', action='store_true')
    ap.add_argument('--vice-labels', metavar='FILE', help='write labels as VICE monitor "al" commands (x64 -moncommands FILE)')
    ap.add_argument('--illegal', action='store_true', help='allow stable illegal opcodes (lax, sax, sbx, dcp, isc, slo, rla, sre, rra, anc, alr, arr, dop, top)')
    a = ap.parse_args()
    src = open(a.source).read()
    try:
        origin, data, labels, listing = assemble(src, illegal=a.illegal)
    except AsmError as ex:
        print(f"ERROR: {ex}", file=sys.stderr); sys.exit(1)
    end = origin + len(data) - 1
    print(f"OK  ${origin:04X}-${end:04X}  ({len(data)} bytes)  sys {origin}", file=sys.stderr)
    if a.listing:
        for n, pc, code, raw in listing:
            addr = f"{pc:04X}" if pc is not None else '    '
            hx = ' '.join(f"{b:02X}" for b in code[:6]) + (' ..' if len(code) > 6 else '')
            print(f"{addr}  {hx:<20} {raw.rstrip()}")
    if a.symbols:
        for k, v in sorted(labels.items(), key=lambda kv: kv[1]):
            print(f"{k:<20} ${v:04X}  {v}")
    if a.output:
        open(a.output, 'wb').write(to_prg(origin, data)); print(f"wrote {a.output}", file=sys.stderr)
    if a.vice_labels:
        with open(a.vice_labels, 'w') as f:
            for k, v in sorted(labels.items(), key=lambda kv: kv[1]):
                if '@' in k: continue                      # locals aren't useful in the monitor
                f.write(f"al {v:04x} .{k.replace('.', '_')}\n")
        print(f"wrote {a.vice_labels} ({sum('@' not in k for k in labels)} labels)", file=sys.stderr)
    if a.data:
        sys.stdout.write(to_basic_data(origin, data, sys_call=not a.nosys))

if __name__ == '__main__':
    main()
