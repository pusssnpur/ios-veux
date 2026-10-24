#!/bin/sh
# Pull and decode the facts unprivileged Android adb cannot read:
# the live FDT memory/cpus/soc nodes, /proc/iomem and dmesg.
#   tools/veux-fdt-pull.sh OUTDIR [-s SERIAL]
#
# Needs a ROOT adb context: LineageOS Recovery (adbd runs as root, no RSA
# prompt) or a fastboot-booted veux shim. On Android the shell domain is
# SELinux-blocked (Enforcing) and file contents are unreadable there.
#
# The recovery shell is minimal (toybox, no find/tar assumed): every read is
# a plain `cat` of a known path or an `ls` of one directory.
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	echo "Usage: $(basename "$0") OUTDIR [-s SERIAL]"
	echo "Pull the live FDT (memory/cpus/soc/chosen), /proc/iomem and dmesg via root adb."
	exit 0
fi

out=${1:?usage: veux-fdt-pull.sh OUTDIR [-s SERIAL]}
shift
ADB="adb"
if [ "${1:-}" = "-s" ]; then
	shift
	serial=${1:?Error: -s requires a device serial}
	shift
	ADB="adb -s $serial"
fi
command -v adb >/dev/null 2>&1 || { echo "Error: adb not found in PATH" >&2; exit 1; }

mkdir -p "$out/fdt"
state=$($ADB get-state 2>/dev/null || true)
[ "$state" = "device" ] || [ "$state" = "recovery" ] || {
	echo "Error: no device in adb (state: ${state:-none})" >&2
	exit 1
}

DT=/proc/device-tree

# cat FILE -> OUT (binary-safe). The remote command gets stderr redirected:
# `adb exec-out` merges the remote stderr into stdout, and an error sentence
# in a .reg file would decode as garbage instead of failing loudly.
pull() {
	if ! $ADB exec-out "cat '$1' 2>/dev/null" >"$2" 2>/dev/null || [ ! -s "$2" ]; then
		$ADB shell "cat '$1' 2>/dev/null" 2>/dev/null | tr -d '\r' >"$2" || true
	fi
	# anything that is not plausible FDT payload (printable error text) is dropped
	if [ -s "$2" ] && head -c 4 "$2" | grep -q '^cat:'; then
		rm -f "$2"
	fi
	[ -s "$2" ] || rm -f "$2"
}

listdir() {
	$ADB shell ls "$1" 2>/dev/null | tr -d '\r' | sed '/^$/d' || true
}

echo "device state: $state; pulling from $DT" >&2

# --- scalar nodes -----------------------------------------------------------
for n in model qcom,board-id qcom,msm-id qcom,pmic-id qcom,pmic-id-size; do
	pull "$DT/$n" "$out/fdt/${n//,/_}"
done
pull "$DT/chosen/bootargs" "$out/fdt/bootargs"

# --- memory node ------------------------------------------------------------
mkdir -p "$out/fdt/memory"
pull "$DT/memory/reg" "$out/fdt/memory/reg"
for c in $(listdir "$DT/memory"); do
	case $c in reg|name|phandle) continue ;; esac
	pull "$DT/memory/$c/reg" "$out/fdt/memory/$c.reg" || true
done

# --- cpus node --------------------------------------------------------------
# children are cpu@0 .. cpu@700 (MPIDR in the unit address), plus cpu-map
mkdir -p "$out/fdt/cpus"
pull "$DT/cpus/#address-cells" "$out/fdt/cpus/address-cells"
pull "$DT/cpus/#size-cells" "$out/fdt/cpus/size-cells"
for c in $(listdir "$DT/cpus"); do
	case $c in cpu@*) ;; *) continue ;; esac
	mkdir -p "$out/fdt/cpus/$c"
	for p in reg compatible clock-frequency timebase-frequency capacity-levels; do
		pull "$DT/cpus/$c/$p" "$out/fdt/cpus/$c/$p" || true
	done
done

# --- soc: the QUP SE UARTs (BT uses SE1) -----------------------------------
mkdir -p "$out/fdt/soc"
pull "$DT/soc/#address-cells" "$out/fdt/soc/address-cells"
pull "$DT/soc/#size-cells" "$out/fdt/soc/size-cells"
for c in $(listdir "$DT/soc"); do
	case $c in qupv3_se*|*uart*|*geni*) ;; *) continue ;; esac
	mkdir -p "$out/fdt/soc/$c"
	pull "$DT/soc/$c/reg" "$out/fdt/soc/$c/reg" || true
	pull "$DT/soc/$c/status" "$out/fdt/soc/$c/status" || true
done

# --- reserved-memory (sizes this time) --------------------------------------
mkdir -p "$out/fdt/reserved-memory"
pull "$DT/reserved-memory/#address-cells" "$out/fdt/reserved-memory/address-cells"
pull "$DT/reserved-memory/#size-cells" "$out/fdt/reserved-memory/size-cells"
for c in $(listdir "$DT/reserved-memory"); do
	case $c in '#'*|name|phandle|ranges) continue ;; esac
	pull "$DT/reserved-memory/$c/reg" "$out/fdt/reserved-memory/$c.reg" || true
done

# --- /proc and kernel log ---------------------------------------------------
pull /proc/iomem "$out/iomem"
pull /proc/meminfo "$out/meminfo"
if ! $ADB exec-out dmesg >"$out/dmesg.txt" 2>/dev/null || [ ! -s "$out/dmesg.txt" ]; then
	$ADB shell dmesg 2>/dev/null | tr -d '\r' >"$out/dmesg.txt" || true
fi

echo "pulled; decoding" >&2
python3 - "$out" <<'PY'
import os, struct, sys

out = sys.argv[1]
fdt = os.path.join(out, 'fdt')

def cells(dirname, default=(2, 2)):
    res = []
    for i, name in enumerate(('address-cells', 'size-cells')):
        try:
            res.append(struct.unpack('>I', open(os.path.join(dirname, name), 'rb').read(4))[0])
        except Exception:
            res.append(default[i])
    return tuple(res)

def regs(dirname, regfile='reg', ac=None, sc=None):
    try:
        raw = open(os.path.join(dirname, regfile), 'rb').read()
    except OSError:
        return []
    if ac is None or sc is None:
        # cell counts come from the PARENT node (dirname itself is the unit)
        ac, sc = cells(os.path.dirname(dirname))
    if len(raw) % 4:
        raw = raw[:len(raw) // 4 * 4]
    vals = struct.unpack('>%dI' % (len(raw) // 4), raw) if raw else []
    out = []
    for i in range(0, len(vals), ac + sc):
        chunk = vals[i:i + ac + sc]
        if len(chunk) < ac + sc:
            break
        addr = int.from_bytes(struct.pack('>%dI' % ac, *chunk[:ac]), 'big')
        size = int.from_bytes(struct.pack('>%dI' % sc, *chunk[ac:]), 'big')
        out.append((addr, size))
    return out

def mib(size):
    return '%.1f MiB' % (size / 1048576) if size >= 1048576 else '%d B' % size

print('=== model / ids ===')
for f in ('model', 'qcom_board-id', 'qcom_msm-id', 'qcom_pmic-id'):
    p = os.path.join(fdt, f)
    if os.path.exists(p):
        raw = open(p, 'rb').read()
        stripped = raw.rstrip(b'\x00')
        if stripped and all(0x20 <= b < 0x7f for b in stripped):
            print('%s: %s' % (f, stripped.decode('ascii')))
        else:
            n = len(raw) // 4
            print('%s: %s' % (f, ' '.join('0x%x' % v for v in struct.unpack('>%dI' % n, raw[:n * 4]))))

print()
print('=== memory banks ===')
md = os.path.join(fdt, 'memory')
mac, msc = cells(md)
banks = regs(md, ac=mac, sc=msc)
for addr, size in banks:
    print('  <0x%x 0x%x>  %s' % (addr, size, mib(size)))
if banks:
    total = sum(s for _, s in banks)
    print('  total: 0x%x = %s' % (total, mib(total)))
else:
    print('  (memory/reg not pulled)')

print()
print('=== cpus ===')
cd = os.path.join(fdt, 'cpus')
# Qualcomm cpus nodes are #address-cells=1/#size-cells=0 (reg = one MPIDR u32)
cac, csc = cells(cd, default=(1, 0))
cpus = sorted(d for d in os.listdir(cd) if os.path.isdir(os.path.join(cd, d)))
# timebase-frequency: some kernels put it on /cpus, holi puts it per-CPU
tb = None
for p in (os.path.join(cd, 'timebase-frequency'),):
    if os.path.exists(p):
        try:
            tb = struct.unpack('>I', open(p, 'rb').read(4))[0]
        except Exception:
            pass
if tb is None and cpus:
    p = os.path.join(cd, cpus[0], 'timebase-frequency')
    if os.path.exists(p):
        try:
            tb = struct.unpack('>I', open(p, 'rb').read(4))[0]
        except Exception:
            pass
if tb:
    print('  timebase-frequency: %d Hz (%.2f MHz)' % (tb, tb / 1e6))
for c in cpus:
    d = os.path.join(cd, c)
    r = regs(d, ac=cac, sc=csc)
    mpidr = r[0][0] if r else None
    comp = ''
    if os.path.exists(os.path.join(d, 'compatible')):
        comp = open(os.path.join(d, 'compatible'), 'rb').read().decode('ascii', 'replace').rstrip('\x00')
    freq = ''
    if os.path.exists(os.path.join(d, 'clock-frequency')):
        raw = open(os.path.join(d, 'clock-frequency'), 'rb').read()
        if len(raw) == 4:
            freq = '%.4f GHz' % (struct.unpack('>I', raw)[0] / 1e9)
        elif len(raw) == 8:
            freq = '%.4f GHz' % (struct.unpack('>Q', raw)[0] / 1e9)
    print('  %-6s mpidr=0x%-6s %s %s' % (c, ('%x' % mpidr) if mpidr is not None else '?', freq, comp))

print()
print('=== soc QUP/UART nodes ===')
sd = os.path.join(fdt, 'soc')
sac, ssc = cells(sd)
for c in sorted(os.listdir(sd)):
    d = os.path.join(sd, c)
    if not os.path.isdir(d):
        continue
    r = regs(d, ac=sac, sc=ssc)
    if not r:
        continue
    status = ''
    if os.path.exists(os.path.join(d, 'status')):
        status = open(os.path.join(d, 'status'), 'rb').read().decode('ascii', 'replace').rstrip('\x00')
    print('  %-28s reg=%s %s' % (c, ' '.join('<0x%x 0x%x>' % x for x in r), status))

print()
print('=== reserved-memory (with sizes) ===')
rd = os.path.join(fdt, 'reserved-memory')
rac, rsc = cells(rd)
regions = []
for c in sorted(os.listdir(rd)):
    # the pull writes child regs as "<child>.reg" flat files
    if not c.endswith('.reg'):
        continue
    for addr, size in regs(rd, regfile=c, ac=rac, sc=rsc):
        regions.append((addr, size, c[:-4]))
for addr, size, name in sorted(regions):
    print('  <0x%x 0x%x> %-14s %s' % (addr, size, name, mib(size)))

print()
print('=== bootargs ===')
p = os.path.join(fdt, 'bootargs')
if os.path.exists(p):
    print(' ', open(p, 'rb').read().decode('ascii', 'replace').rstrip('\x00'))
else:
    print('  (not pulled)')

print()
print('=== /proc/iomem (System RAM) ===')
p = os.path.join(out, 'iomem')
if os.path.exists(p):
    lines = open(p, errors='replace').read().splitlines()
    ram = [l for l in lines if 'System RAM' in l]
    print('\n'.join('  ' + l.strip() for l in ram) if ram else '  (no entries readable)')
PY

echo "done: $out/{fdt,iomem,meminfo,dmesg.txt}" >&2
