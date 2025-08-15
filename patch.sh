#!/usr/bin/env bash
set -euo pipefail

# -------- helpers --------
die(){ echo "ERROR: $*" >&2; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

need awk; need perl; need sed; need make; need python3

CFG="${1:-}"
shift || true

# -------- step 0: sanity / where am i? --------
[[ -f Makefile && -f Result.cpp && -f main.cpp ]] || die "run from NVSim repo root (Makefile/Result.cpp/main.cpp must exist)."

# -------- step 1: restore a clean Result.cpp from the last backup (fixes the '...' bug) --------
last_backup="$(ls -1dt backup_before_plumbing_* 2>/dev/null | head -1 || true)"
if [[ -n "${last_backup}" && -f "${last_backup}/Result.cpp" ]]; then
  echo "[repair] restoring Result.cpp from ${last_backup}"
  cp -f "${last_backup}/Result.cpp" Result.cpp
else
  echo "[repair] no backup_before_plumbing_* found; keeping current Result.cpp"
fi

# -------- step 2: append tiny tRC_ns computation to CSV safely (DRAM/eDRAM only) --------
# Insert tRC calc snippet once (if not already present)
if ! grep -q 'tRC_ns' Result.cpp; then
  echo "[patch] adding tRC_ns computation + CSV column"
  awk '
  BEGIN{added=0}
  {
    print $0
    # After we compute read/write latency numbers for CSV, we add our block near the end of printToCsvFile
    if ($0 ~ /^void Result::printToCsvFile\(ofstream &outputFile\) \{/) { infunc=1 }
    if (infunc && $0 ~ /outputFile << bank->leakage \* 1e3 << ",\";$/ && !added) {
      print ""
      print "        /* --- tRC_ns (only non-zero for DRAM/eDRAM) --- */"
      print "        double tRC_ns = 0.0;"
      print "        if (cell->memCellType == DRAM || cell->memCellType == eDRAM) {"
      print "            double senseLat = inputParameter->internalSensing ? bank->mat.subarray.senseAmp.readLatency : 0.0;"
      print "            double muxLat = bank->mat.subarray.bitlineMux.readLatency"
      print "                + bank->mat.subarray.senseAmpMuxLev1.readLatency"
      print "                + bank->mat.subarray.senseAmpMuxLev2.readLatency;"
      print "            tRC_ns = (bank->mat.subarray.rowDecoder.readLatency"
      print "                    + bank->mat.subarray.bitlineDelay"
      print "                    + senseLat + muxLat"
      print "                    + bank->mat.subarray.precharger.readLatency) * 1e9;"
      print "        }"
      print "        outputFile << tRC_ns << \",\";"
      added=1
    }
    if (infunc && $0 ~ /^\}/) { infunc=0 }
  }' Result.cpp > Result.cpp.tmp && mv Result.cpp.tmp Result.cpp
fi

# Also include algorithm/sstream headers if not present (for safety if downstream patches use them)
if ! grep -q '<algorithm>' Result.cpp; then
  sed -i '1,40 s|#include <fstream>|#include <fstream>\n#include <algorithm>\n#include <sstream>|' Result.cpp
fi

# -------- step 3: rebuild NVSim --------
echo "[build] make -j"
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

echo "[ok] NVSim builds."

# -------- step 4 (optional): run + postprocess to CSV with all (1)-(5) fields --------
# We keep all (1)-(5) in postprocess to avoid heavy invasive edits to NVSim.
# If no cfg is provided, we stop here.
if [[ -z "${CFG}" ]]; then
  echo "[note] no cfg provided; skipping run+post. You can re-run as:"
  echo "  bash $0 sample_NVM_macro.cfg --banks 1 --nvm_headroom 0.9 --ecc_alpha 0.125 ..."
  exit 0
fi

[[ -f "${CFG}" ]] || die "cfg not found: ${CFG}"

# Parse CLI knobs for (1)-(5)
# defaults
banks=1
nvm_headroom=0.9
ecc_alpha=0.0
ecc_area_frac=0.0
ecc_energy_frac_logic=0.0
ecc_on_link=false
d2d_cap_GBs=0.0
link_pj_per_bit=0.0
retention_E_pJ_per_MB=0.0
retention_T_s=0.0
retention_temp_factor=1.0
endurance_cycles=0
endurance_write_factor=1.0
endurance_time_factor=1.0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --banks) banks="$2"; shift 2;;
    --nvm_headroom) nvm_headroom="$2"; shift 2;;
    --ecc_alpha) ecc_alpha="$2"; shift 2;;
    --ecc_area_frac) ecc_area_frac="$2"; shift 2;;
    --ecc_energy_frac_logic) ecc_energy_frac_logic="$2"; shift 2;;
    --ecc_on_link) ecc_on_link=true; shift 1;;
    --d2d_cap_GBs) d2d_cap_GBs="$2"; shift 2;;
    --link_pj_per_bit) link_pj_per_bit="$2"; shift 2;;
    --retention_E_pJ_per_MB) retention_E_pJ_per_MB="$2"; shift 2;;
    --retention_T_s) retention_T_s="$2"; shift 2;;
    --retention_temp_factor) retention_temp_factor="$2"; shift 2;;
    --endurance_cycles) endurance_cycles="$2"; shift 2;;
    --endurance_write_factor) endurance_write_factor="$2"; shift 2;;
    --endurance_time_factor) endurance_time_factor="$2"; shift 2;;
    *) die "unknown arg: $1";;
  esac
done

out_txt="run_${CFG##*/}.txt"
echo "[run] ./nvsim ${CFG} | tee ${out_txt}"
./nvsim "${CFG}" | tee "${out_txt}"

# Python post-processor emits metrics.csv (appends rows)
python3 - "$CFG" "$out_txt" << 'PY'
import re, sys, math, json, os, csv

cfg, txt = sys.argv[1], sys.argv[2]

# read stdout
with open(txt,'r') as f: s=f.read()

def pick(pattern, flags=0, cast=float, default=None):
    m=re.search(pattern,s,flags)
    if not m: return default
    try:
        return cast(m.group(1))
    except:
        return default

def pick_str(pattern, default=""):
    m=re.search(pattern,s)
    return (m.group(1).strip() if m else default)

# parse basic pieces
mem_type = pick_str(r"Memory Cell:\s*([^\n]+)")
data_width_bits = pick(r"Data Width\s*:\s*([0-9]+)Bits", cast=int, default=None)
line_bytes = None
if data_width_bits: line_bytes = data_width_bits/8.0
# Cache line (if cache)
m=re.search(r"Cache Line Size:\s*([0-9]+)Bytes", s)
if m: line_bytes=float(m.group(1))

# Areas (um and um^2 in print(); take totals)
total_area_um2 = pick(r"Total Area = [^=]+=\s*([0-9.]+)um\^2")
area_mm2 = (total_area_um2/1e6) if total_area_um2 else None

# Latencies
read_lat_ns = pick(r"-\s*Read Latency\s*=\s*([0-9.]+)ns")
write_lat_ns = pick(r"-\s*Write Latency\s*=\s*([0-9.]+)ns")
predec_ps = pick(r"Predecoder Latency\s*=\s*([0-9.]+)ps")
rowdec_ps = pick(r"Row Decoder Latency\s*=\s*([0-9.]+)ps")
bitline_ps = pick(r"Bitline Latency\s*=\s*([0-9.]+)ps")
sense_ns = pick(r"Senseamp Latency\s*=\s*([0-9.]+)ns", default=0.0)
mux_ps = pick(r"Mux Latency\s*=\s*([0-9.]+)ps", default=0.0)
prech_ps = pick(r"Precharge Latency\s*=\s*([0-9.]+)ps", default=0.0)

# Bandwidth
read_bw_str = pick_str(r"Read Bandwidth\s*=\s*([0-9.]+[A-Z]*B/s)")
write_bw_str= pick_str(r"Write Bandwidth\s*=\s*([0-9.]+[A-Z]*B/s)")
def to_Bps(s):
    if not s: return None
    m=re.match(r"([0-9.]+)([KMGT]?B)/s", s)
    if not m: return None
    x=float(m.group(1)); u=m.group(2)
    mult={"B":1,"KB":1e3,"MB":1e6,"GB":1e9,"TB":1e12}[u]
    return x*mult
read_Bps = to_Bps(read_bw_str)
write_Bps= to_Bps(write_bw_str)
perbank_peak_GBs = (max(read_Bps or 0, write_Bps or 0)/1e9) if (read_Bps or write_Bps) else None

# Energies (J reported; stdout shows pJ on sub-parts but totals are in J via macros)
read_E_J = pick(r"Read Dynamic Energy\s*=\s*([0-9.]+)p?J")
write_E_J= pick(r"Write Dynamic Energy\s*=\s*([0-9.]+)p?J")
# If macros printed pJ, detect by context (the sample prints pJ)
if 'pJ' in s:
    # convert pJ -> J for totals we captured
    if read_E_J is not None: read_E_J *= 1e-12
    if write_E_J is not None: write_E_J *= 1e-12

leak_mW = pick(r"Leakage Power\s*=\s*([0-9.]+)mW")

# config from cfg file (process, tech, temp K)
proc_nm = None; tech_str=""; tempK=None
with open(cfg,'r') as f:
    for line in f:
        if line.startswith("-ProcessNode"): proc_nm = int(re.search(r":\s*([0-9]+)",line).group(1))
        if line.startswith("-DeviceRoadmap"):
            v=line.split(":")[1].strip()
            tech_str=("HP" if "HP" in v else "LSTP" if "LSTP" in v else "LOP")
        if line.startswith("-Temperature"): tempK = float(re.search(r":\s*([0-9.]+)",line).group(1))
        if line.startswith("-WordWidth") and line_bytes is None:
            ww=int(re.search(r"\((?:bit)\):\s*([0-9]+)",line).group(1))
            line_bytes=ww/8.0

op_temp_C = (tempK-273.15) if tempK is not None else None

# CLI knobs from env (passed by shell)
knobs=json.loads(os.environ.get("NVP_KNOBS","{}"))
banks=int(knobs["banks"])
nvm_headroom=float(knobs["nvm_headroom"])
ecc_alpha=float(knobs["ecc_alpha"])
ecc_area_frac=float(knobs["ecc_area_frac"])
ecc_energy_frac_logic=float(knobs["ecc_energy_frac_logic"])
ecc_on_link=bool(knobs["ecc_on_link"])
d2d_cap_GBs=float(knobs["d2d_cap_GBs"])
link_pj_per_bit=float(knobs["link_pj_per_bit"])
retention_E_pJ_per_MB=float(knobs["retention_E_pJ_per_MB"])
retention_T_s=float(knobs["retention_T_s"])
retention_temp_factor=float(knobs["retention_temp_factor"])
endurance_cycles=float(knobs["endurance_cycles"])
endurance_write_factor=float(knobs["endurance_write_factor"])
endurance_time_factor=float(knobs["endurance_time_factor"])

# derived
bytes_per_access = line_bytes or 0.0
read_pJ_per_B  = (read_E_J*1e12/bytes_per_access) if (read_E_J is not None and bytes_per_access>0) else None
write_pJ_per_B = (write_E_J*1e12/bytes_per_access) if (write_E_J is not None and bytes_per_access>0) else None
read_pJ_per_payloadB  = (read_pJ_per_B  or 0.0)*(1+ecc_alpha)*(1+ecc_energy_frac_logic) if read_pJ_per_B is not None else None
write_pJ_per_payloadB = (write_pJ_per_B or 0.0)*(1+ecc_alpha)*(1+ecc_energy_frac_logic) if write_pJ_per_B is not None else None

cap_nvm_GBs = (nvm_headroom * banks * (perbank_peak_GBs or 0.0)) if perbank_peak_GBs is not None else None
cap_effective_GBs = min(cap_nvm_GBs or 0.0, d2d_cap_GBs or float("inf")) if (cap_nvm_GBs is not None and d2d_cap_GBs>0) else cap_nvm_GBs

e_link_pJ_per_payloadB = 8.0*link_pj_per_bit*(1 + (ecc_alpha if ecc_on_link else 0.0))

# Retention background power
# capacity payload MB not directly in stdout; estimate from area? Not needed: just omit if unknown.
# We can approximate from Data Width if Capacity is in cfg; parse:
cap_bytes=None
with open(cfg,'r') as f:
    for line in f:
        if line.startswith("-Capacity (B)"): cap_bytes=int(re.search(r":\s*([0-9]+)",line).group(1))
        if line.startswith("-Capacity (KB)"): cap_bytes=int(re.search(r":\s*([0-9]+)",line).group(1))*1024
        if line.startswith("-Capacity (MB)"): cap_bytes=int(re.search(r":\s*([0-9]+)",line).group(1))*1024*1024

cap_payload_MB = None
if cap_bytes is not None:
    cap_MB = cap_bytes/1024.0/1024.0
    cap_payload_MB = cap_MB/(1+ecc_alpha)

retention_mW=None
if cap_payload_MB is not None and retention_E_pJ_per_MB>0 and retention_T_s>0:
    retention_mW = (retention_E_pJ_per_MB * cap_payload_MB * retention_temp_factor) / retention_T_s * 1e-9

# tRC estimate from components (if present)
# Use: tRC ≈ RowDecoder + Bitline + Senseamp (if present) + Mux + Precharge
def ps_to_ns(x): return (x or 0.0)/1000.0
tRC_ns = None
if mem_type and ("DRAM" in mem_type or "Embedded" in mem_type or "eDRAM" in mem_type):
    tRC_ns = ps_to_ns(rowdec_ps) + ps_to_ns(bitline_ps) + (sense_ns or 0.0) + ps_to_ns(mux_ps) + ps_to_ns(prech_ps)

# corner id
corner = "{}_{}_{}nm_{}C".format(
    (mem_type.split()[0] if mem_type else "NVM"),
    (tech_str or "HP"),
    (proc_nm or 0),
    int(round(op_temp_C)) if op_temp_C is not None else 25
)

# CSV
hdr = [
 "nvm_corner_id","process_nm","tech","op_temp_C",
 "line_bytes","read_latency_ns","write_latency_ns","tRC_ns",
 "read_energy_pJ_per_B","write_energy_pJ_per_B",
 "read_energy_pJ_per_payloadB","write_energy_pJ_per_payloadB",
 "leakage_mW","area_mm2",
 "banks","nvm_headroom","perbank_peak_GBs","cap_nvm_GBs","d2d_cap_GBs","cap_effective_GBs",
 "e_link_pJ_per_payloadB",
 "ecc_alpha","ecc_area_frac","ecc_energy_frac_logic","ecc_on_link",
 "retention_mW",
 "endurance_cycles","endurance_write_factor","endurance_time_factor"
]

row = [
 corner, proc_nm, tech_str, op_temp_C,
 line_bytes, read_lat_ns, write_lat_ns, tRC_ns,
 read_pJ_per_B, write_pJ_per_B,
 read_pJ_per_payloadB, write_pJ_per_payloadB,
 leak_mW, area_mm2,
 banks, nvm_headroom, perbank_peak_GBs, cap_nvm_GBs, d2d_cap_GBs, cap_effective_GBs,
 e_link_pJ_per_payloadB,
 ecc_alpha, ecc_area_frac, ecc_energy_frac_logic, ecc_on_link,
 retention_mW,
 endurance_cycles, endurance_write_factor, endurance_time_factor
]

outcsv="metrics.csv"
exists=os.path.exists(outcsv)
with open(outcsv,"a",newline="") as f:
    w=csv.writer(f)
    if not exists: w.writerow(hdr)
    w.writerow(row)

print(f"[post] wrote/updated {outcsv}")
PY
# pass knobs to python via env as JSON
export NVP_KNOBS="$(jq -n \
  --argjson banks "$banks" \
  --argjson nvm_headroom "$nvm_headroom" \
  --argjson ecc_alpha "$ecc_alpha" \
  --argjson ecc_area_frac "$ecc_area_frac" \
  --argjson ecc_energy_frac_logic "$ecc_energy_frac_logic" \
  --argjson ecc_on_link "$( $ecc_on_link && echo true || echo false )" \
  --argjson d2d_cap_GBs "$d2d_cap_GBs" \
  --argjson link_pj_per_bit "$link_pj_per_bit" \
  --argjson retention_E_pJ_per_MB "$retention_E_pJ_per_MB" \
  --argjson retention_T_s "$retention_T_s" \
  --argjson retention_temp_factor "$retention_temp_factor" \
  --argjson endurance_cycles "$endurance_cycles" \
  --argjson endurance_write_factor "$endurance_write_factor" \
  --argjson endurance_time_factor "$endurance_time_factor" )"

echo "[done] NVSim fixed. metrics.csv now contains your (1)-(5) fields."
