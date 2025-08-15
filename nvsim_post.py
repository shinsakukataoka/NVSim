import argparse, math, os, re, sys

def parse_cfg(path):
    out = {
        "process_nm": None, "temp_K": None, "device": None,
        "word_width_bits": None, "design": None,
        "capacity_B": None, "memcell_file": None,
    }
    if not path: return out
    pat_val = lambda k: re.compile(rf'^{re.escape(k)}\s*:\s*(.+)\s*$')
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            line=line.strip()
            m = re.match(r'^-ProcessNode:\s*(\d+)', line);        out["process_nm"] = int(m.group(1)) if m else out["process_nm"]
            m = re.match(r'^-Temperature \(K\):\s*(\d+)', line);  out["temp_K"] = int(m.group(1)) if m else out["temp_K"]
            m = re.match(r'^-DeviceRoadmap:\s*(HP|LSTP|LOP)', line); out["device"] = m.group(1) if m else out["device"]
            m = re.match(r'^-WordWidth \(bit\):\s*(\d+)', line);  out["word_width_bits"] = int(m.group(1)) if m else out["word_width_bits"]
            m = re.match(r'^-DesignTarget:\s*(\S+)', line);       out["design"] = m.group(1) if m else out["design"]
            m = re.match(r'^-MemoryCellInputFile:\s*(\S+)', line); out["memcell_file"] = os.path.basename(m.group(1)) if m else out["memcell_file"]
            # Capacity (B|KB|MB)
            m = re.match(r'^-Capacity \(B\):\s*(\d+)', line)
            if m: out["capacity_B"] = int(m.group(1)); continue
            m = re.match(r'^-Capacity \(KB\):\s*(\d+)', line)
            if m: out["capacity_B"] = int(m.group(1)) * 1024; continue
            m = re.match(r'^-Capacity \(MB\):\s*(\d+)', line)
            if m: out["capacity_B"] = int(m.group(1)) * 1024 * 1024; continue
    return out

def to_float(x):
    try:
        return float(x)
    except:
        return math.nan

def parse_nvsim_row(line, expect_trailing_trc=True):
    # NVSim CSV has no header and many textual fields. We index from the tail.
    toks = [t.strip() for t in line.strip().split(',')]
    # drop trailing empties from the final ","
    while toks and toks[-1]=='':
        toks.pop()
    if not toks:
        return None
    # Layout at tail (after our tRC injection):
    # [..., bank.height_um, bank.width_um, bank.area_mm2,
    #     mat.height_um, mat.width_um, mat.area_mm2,
    #     sub.height_um, sub.width_um, sub.area_mm2,
    #     area_eff_percent,
    #     read_lat_ns, write_lat_ns, read_E_pJ, write_E_pJ, leakage_mW, tRC_ns]
    # If tRC_ns was NOT injected, the last field is leakage_mW; handle both.
    if expect_trailing_trc and len(toks) >= 16:
        area_mm2         = to_float(toks[-14])
        read_lat_ns      = to_float(toks[-6])
        write_lat_ns     = to_float(toks[-5])
        read_E_pJ        = to_float(toks[-4])
        write_E_pJ       = to_float(toks[-3])
        leakage_mW       = to_float(toks[-2])
        tRC_ns           = to_float(toks[-1])
    else:
        # fallback (no tRC_ns)
        if len(toks) < 15:
            return None
        area_mm2         = to_float(toks[-13])
        read_lat_ns      = to_float(toks[-5])
        write_lat_ns     = to_float(toks[-4])
        read_E_pJ        = to_float(toks[-3])
        write_E_pJ       = to_float(toks[-2])
        leakage_mW       = to_float(toks[-1])
        tRC_ns           = math.nan
    return {
        "area_mm2": area_mm2,
        "read_lat_ns": read_lat_ns,
        "write_lat_ns": write_lat_ns,
        "read_E_pJ": read_E_pJ,
        "write_E_pJ": write_E_pJ,
        "leakage_mW": leakage_mW,
        "tRC_ns": tRC_ns,
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("--cfg", default=None, help="NVSim .cfg to derive line_bytes, process, temp, tech, capacity")
    ap.add_argument("--banks", type=int, default=1)
    ap.add_argument("--nvm_headroom", type=float, default=0.9)
    ap.add_argument("--ecc_alpha", type=float, default=0.0)
    ap.add_argument("--ecc_area_frac", type=float, default=0.0)
    ap.add_argument("--ecc_energy_frac_logic", type=float, default=0.0)
    ap.add_argument("--ecc_on_link", action="store_true")
    ap.add_argument("--d2d_cap_GBs", type=float, default=1e9)
    ap.add_argument("--link_pj_per_bit", type=float, default=0.0)
    ap.add_argument("--retention_E_pJ_per_MB", type=float, default=0.0)
    ap.add_argument("--retention_T_s", type=float, default=1.0)
    ap.add_argument("--retention_temp_factor", type=float, default=1.0)
    ap.add_argument("--endurance_cycles", type=float, default=0.0)
    ap.add_argument("--endurance_write_factor", type=float, default=1.0)
    ap.add_argument("--endurance_time_factor", type=float, default=1.0)
    args = ap.parse_args()

    cfg = parse_cfg(args.cfg) if args.cfg else {}
    # line_bytes
    line_bytes = None
    if cfg.get("word_width_bits"):
        line_bytes = cfg["word_width_bits"] // 8
    # metadata
    process_nm = cfg.get("process_nm")
    tech = cfg.get("device")
    op_temp_C = (cfg.get("temp_K") - 273.15) if cfg.get("temp_K") is not None else None
    capacity_MB = (cfg.get("capacity_B") / (1024*1024)) if cfg.get("capacity_B") else None
    memcorner = cfg.get("memcell_file") or "NVM"

    # output header
    cols = [
        "area_mm2","area_total_mm2",
        "read_lat_ns","write_lat_ns","read_E_pJ","write_E_pJ","leakage_mW","tRC_ns",
        "read_E_pJ_per_B_raw","write_E_pJ_per_B_raw",
        "read_E_pJ_per_payload_B","write_E_pJ_per_payload_B",
        "process_nm","tech","op_temp_C","line_bytes","banks","nvm_corner_id",
        "cap_effective_Bps","cap_effective_payload_Bps","e_link_pJ_per_B","P_retention_mW",
        "capacity_raw_MB","capacity_payload_MB",
        "Ew_endurance_scaled_pJ","tw_endurance_scaled_ns","endurance_cycles"
    ]
    print(",".join(cols))

    with open(args.infile, 'r', encoding='utf-8') as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            r = parse_nvsim_row(raw, expect_trailing_trc=True)
            if not r:
                continue

            # ECC ratios
            payload_ratio = 1.0 / (1.0 + args.ecc_alpha) if args.ecc_alpha > 0 else 1.0

            # energies per byte (need line_bytes)
            if not line_bytes or line_bytes <= 0:
                read_pJ_per_B_raw = math.nan
                write_pJ_per_B_raw = math.nan
                read_pJ_per_payload_B = math.nan
                write_pJ_per_payload_B = math.nan
            else:
                read_pJ_per_B_raw  = r["read_E_pJ"]  / line_bytes
                write_pJ_per_B_raw = r["write_E_p_J"] if False else r["write_E_pJ"] / line_bytes  # keep naming consistent
                logic_scale = (1.0 + args.ecc_energy_frac_logic)
                ecc_expand  = (1.0 + args.ecc_alpha)
                read_pJ_per_payload_B  = read_pJ_per_B_raw  * ecc_expand * logic_scale
                write_pJ_per_payload_B = write_pJ_per_B_raw * ecc_expand * logic_scale

            # link energy per payload byte (w/ optional ECC on link)
            e_link = 8.0 * args.link_pj_per_bit * (1.0 + (args.ecc_alpha if args.ecc_on_link else 0.0))

            # capacity limit (NVM vs D2D)
            # per-bank peak via simple line_bytes / read_lat
            if line_bytes and r["read_lat_ns"] and r["read_lat_ns"] > 0:
                per_bank_Bps = line_bytes / (r["read_lat_ns"] * 1e-9)
            else:
                per_bank_Bps = math.nan
            cap_nvm = args.nvm_headroom * args.banks * per_bank_Bps if not math.isnan(per_bank_Bps) else math.nan
            cap_d2d = args.d2d_cap_GBs * 1e9
            cap_d2d_payload = cap_d2d / (1.0 + args.ecc_alpha) if args.ecc_on_link else cap_d2d
            cap_effective = min(cap_nvm, cap_d2d) if (not math.isnan(cap_nvm)) else cap_d2d
            cap_effective_payload = min(cap_nvm, cap_d2d_payload) if (not math.isnan(cap_nvm)) else cap_d2d_payload

            # retention background power (printed separately)
            if capacity_MB:
                P_retention_W = (args.retention_E_pJ_per_MB * 1e-12 * capacity_MB / max(args.retention_T_s, 1e-30)) * args.retention_temp_factor
                P_retention_mW = P_retention_W * 1e3
            else:
                P_retention_mW = math.nan

            # endurance scaled
            Ew_scaled = r["write_E_pJ"] * args.endurance_write_factor
            tw_scaled = r["write_lat_ns"] * args.endurance_time_factor

            area_total = r["area_mm2"] * (1.0 + args.ecc_area_frac)
            cap_raw_MB   = capacity_MB if capacity_MB is not None else math.nan
            cap_pay_MB   = (capacity_MB * payload_ratio) if capacity_MB is not None else math.nan

            row = [
                f"{r['area_mm2']}", f"{area_total}",
                f"{r['read_lat_ns']}",
                f"{r['write_lat_ns']}",
                f"{r['read_E_pJ']}",
                f"{r['write_E_pJ']}",
                f"{r['leakage_mW']}",
                f"{r['tRC_ns']}",
                f"{read_pJ_per_B_raw}",
                f"{write_pJ_per_B_raw}",
                f"{read_pJ_per_payload_B}",
                f"{write_pJ_per_payload_B}",
                f"{process_nm if process_nm is not None else ''}",
                f"{tech if tech is not None else ''}",
                f"{op_temp_C if op_temp_C is not None else ''}",
                f"{line_bytes if line_bytes is not None else ''}",
                f"{args.banks}",
                f"{memcorner}_{tech or 'TECH'}_{process_nm or 'PNM'}nm_{(int(op_temp_C) if op_temp_C is not None else 'TEMP')}C",
                f"{cap_effective}",
                f"{cap_effective_payload}",
                f"{e_link}",
                f"{P_retention_mW}",
                f"{cap_raw_MB}",
                f"{cap_pay_MB}",
                f"{Ew_scaled}",
                f"{tw_scaled}",
                f"{args.endurance_cycles}",
            ]
            print(",".join(row))

if __name__ == "__main__":
    main()