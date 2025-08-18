#!/usr/bin/env python3
import argparse, math, os, re, sys, glob, subprocess, time
import json, hashlib

# ---------------------- helpers: cfg parsing & csv tail parse ----------------------

def parse_cfg(path):
    out = {
        "process_nm": None, "temp_K": None, "device": None,
        "word_width_bits": None, "design": None,
        "capacity_B": None, "memcell_file": None,
        "output_prefix": "output",
    }
    if not path: return out
    with open(path, 'r', encoding='utf-8') as f:
        for raw in f:
            line = raw.strip()
            m = re.match(r'^-ProcessNode:\s*(\d+)', line)
            if m: out["process_nm"] = int(m.group(1)); continue
            m = re.match(r'^-Temperature \(K\):\s*(\d+)', line)
            if m: out["temp_K"] = int(m.group(1)); continue
            m = re.match(r'^-DeviceRoadmap:\s*(HP|LSTP|LOP)', line)
            if m: out["device"] = m.group(1); continue
            m = re.match(r'^-WordWidth \(bit\):\s*(\d+)', line)
            if m: out["word_width_bits"] = int(m.group(1)); continue
            m = re.match(r'^-DesignTarget:\s*(\S+)', line)
            if m: out["design"] = m.group(1); continue
            m = re.match(r'^-MemoryCellInputFile:\s*(\S+)', line)
            if m: out["memcell_file"] = os.path.basename(m.group(1)); continue
            m = re.match(r'^-OutputFilePrefix:\s*(\S+)', line)
            if m: out["output_prefix"] = m.group(1); continue
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
    except Exception:
        return math.nan

def parse_nvsim_row(line):
    toks = [t.strip() for t in line.strip().split(',') if t.strip() != '']
    try:
        i = next(k for k, t in enumerate(toks)
                 if t in ("Latency-Optimized", "Balanced", "Area-Optimized"))
    except StopIteration:
        return None
    nums = toks[i+1:i+16]              # 15 fixed numerics
    if len(nums) < 15:
        return None
    vals = list(map(to_float, nums))
    tRC_tok_idx = i + 16
    tRC_ns = to_float(toks[tRC_tok_idx]) if tRC_tok_idx < len(toks) else math.nan
    return {
        "area_mm2":     vals[2],
        "read_lat_ns":  vals[10],
        "write_lat_ns": vals[11],
        "read_E_pJ":    vals[12],
        "write_E_pJ":   vals[13],
        "leakage_mW":   vals[14],
        "tRC_ns":       tRC_ns,  # fixed position right after the 15-number block
    }

# ---------------------- run NVSim once & locate CSV ----------------------

def newest_csv_with_prefix(prefix, where="."):
    cand = sorted(glob.glob(os.path.join(where, f"{prefix}_*.csv")),
                  key=lambda p: os.path.getmtime(p), reverse=True)
    return cand[0] if cand else None

def run_nvsim_and_get_csv(nvsim_bin, cfg_path, prefix_hint=None):
    """
    Run NVSim once and return the absolute path to the newest output CSV that matches
    OutputFilePrefix (or prefix_hint). We run with cwd = directory of the NVSim binary
    so relative resource paths in the cfg (e.g., cell files) resolve correctly.
    """
    repo_dir = os.path.dirname(os.path.abspath(nvsim_bin))
    cfg_abs  = os.path.abspath(cfg_path)
    # prefer prefix from cfg if not provided
    if prefix_hint is None:
        c = parse_cfg(cfg_abs)
        prefix_hint = c.get("output_prefix") or "output"

    proc = subprocess.run([nvsim_bin, cfg_abs],
                          cwd=repo_dir,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT,
                          text=True)
    out = proc.stdout or ""
    if proc.returncode != 0:
        print("[nvsim_post] NVSim failed; output follows:\n" + out, file=sys.stderr)
        return None

    # Try to parse the exact filename NVSim prints
    m = re.search(r'([A-Za-z0-9_.-]+\.csv)\s+generated successfully!', out)
    if m:
        csv_path = os.path.join(repo_dir, m.group(1))
        if os.path.isfile(csv_path) and os.path.getsize(csv_path) > 0:
            return csv_path

    # Fallback: newest CSV with our prefix
    time.sleep(0.05)  # small fs settle
    csv_path = newest_csv_with_prefix(prefix_hint, where=repo_dir)
    if not csv_path:
        print("[nvsim_post] NVSim ran but no CSV found.\n" + out, file=sys.stderr)
        return None
    if os.path.getsize(csv_path) == 0:
        print(f"[nvsim_post] CSV is empty ({os.path.basename(csv_path)}). NVSim said:\n{out}", file=sys.stderr)
        return None
    return csv_path

# ---------------------- device-pack emit helper ----------------------

def write_device_pack(out_path, first_pack, args, cfg):
    pack = {
        "name": f"device_from_nvsim_{(args.device_type or 'NVM').lower()}",
        "meta": {
            "pack_sha": "",
            "tool_version": "nvsim_post.py",
            "source": "nvsim",
            "date": time.strftime("%Y-%m-%d"),
        },
        "nvm": {
            "type": args.device_type,
            "e_const_commit_pJ": args.e_commit_pj,
            "l_const_commit_ns": args.l_commit_ns,
            "e_read_pJ_per_B": first_pack["e_read"],
            "e_write_pJ_per_B": first_pack["e_write"],
            "t_read_ns": first_pack["t_read_ns"],
            "t_write_ns": first_pack["t_write_ns"],
            "leakage_mW_per_bank": first_pack["leakage_mW"],
            "endurance_cycles": args.endurance_cycles,
        },
        "sram": {
            "e_read_pJ_per_B": args.sram_e_read,
            "e_write_pJ_per_B": args.sram_e_write,
            "t_read_ns": args.sram_t_read,
            "t_write_ns": args.sram_t_write,
            "leakage_mW_per_bank": args.sram_leak,
        },
    }
    # optional meta passthrough
    if cfg and cfg.get("process_nm") is not None:
        pack["meta"]["process_nm"] = cfg["process_nm"]
    if cfg and cfg.get("device"):
        pack["meta"]["device"] = cfg["device"]

    # stable SHA over (nvm+sram)
    digest = hashlib.sha256(
        json.dumps({"nvm": pack["nvm"], "sram": pack["sram"]},
                   sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    pack["meta"]["pack_sha"] = digest

    with open(out_path, "w", encoding="utf-8") as fp:
        json.dump(pack, fp, indent=2)
    print(f"[nvsim_post] wrote device pack → {out_path}", file=sys.stderr)

# ---------------------- main (single run only) ----------------------

def main():
    ap = argparse.ArgumentParser(description="NVSim CSV post-processor (single run only).")
    ap.add_argument("infile", nargs="?", help="NVSim CSV to parse (if omitted, use --run to invoke NVSim).")
    ap.add_argument("--run", action="store_true", help="Run NVSim once using --cfg and parse its newest CSV.")
    ap.add_argument("--cfg", default=None, help="NVSim .cfg (used for metadata and required with --run).")
    ap.add_argument("--nvsim_bin", default="./nvsim", help="Path to NVSim binary (used with --run).")

    # System/link/ECC knobs (all single-run)
    ap.add_argument("--banks", type=int, default=1)
    ap.add_argument("--nvm_headroom", type=float, default=0.9)
    ap.add_argument("--ecc_alpha", type=float, default=0.0, help="ECC redundancy ratio (parity/data).")
    ap.add_argument("--ecc_area_frac", type=float, default=0.0, help="Area overhead fraction for ECC metadata.")
    ap.add_argument("--ecc_energy_frac_logic", type=float, default=0.0, help="Extra logic energy fraction.")
    ap.add_argument("--ecc_on_link", action="store_true", help="If set, apply ECC expansion to link energy.")
    ap.add_argument("--d2d_cap_GBs", type=float, default=1e9, help="Die-to-die max bandwidth (GB/s).")
    ap.add_argument("--link_pj_per_bit", type=float, default=0.0)
    ap.add_argument("--retention_E_pJ_per_MB", type=float, default=0.0)
    ap.add_argument("--retention_T_s", type=float, default=1.0)
    ap.add_argument("--retention_temp_factor", type=float, default=1.0)
    ap.add_argument("--endurance_cycles", type=float, default=0.0)
    ap.add_argument("--endurance_write_factor", type=float, default=1.0)
    ap.add_argument("--endurance_time_factor", type=float, default=1.0)

    # Emit NVSuite device pack (JSON)
    ap.add_argument("--emit-device-pack", dest="emit_device_pack", default=None,
                    help="Write NVSuite device JSON from first parsed row.")
    ap.add_argument("--device-type", default="eMRAM")
    ap.add_argument("--e-commit-pj", type=float, default=200.0, dest="e_commit_pj")
    ap.add_argument("--l-commit-ns", type=float, default=100.0, dest="l_commit_ns")
    ap.add_argument("--energies-from", choices=["payload","raw"], default="payload",
                    dest="energies_from",
                    help="Choose energies per byte from payload (includes ECC/logic) or raw.")

    # Simple SRAM defaults (override or use --sram-pack)
    ap.add_argument("--sram-e-read",  type=float, default=0.3, dest="sram_e_read")
    ap.add_argument("--sram-e-write", type=float, default=0.4, dest="sram_e_write")
    ap.add_argument("--sram-t-read",  type=float, default=2.0, dest="sram_t_read")
    ap.add_argument("--sram-t-write", type=float, default=2.0, dest="sram_t_write")
    ap.add_argument("--sram-leak",    type=float, default=0.8, dest="sram_leak")
    ap.add_argument("--sram-pack", default=None,
                    help="Path to JSON with SRAM keys: e_read_pJ_per_B, e_write_pJ_per_B, leakage_mW_per_bank, t_read_ns, t_write_ns")

    args = ap.parse_args()

    # clamp headroom to [0,1]
    args.nvm_headroom = max(0.0, min(args.nvm_headroom, 1.0))

    # Optionally load SRAM pack from JSON
    if args.sram_pack:
        with open(args.sram_pack, "r", encoding="utf-8") as fp:
            s = json.load(fp)
        src = s.get("sram", s)  # allow either top-level or {"sram": {...}}
        args.sram_e_read  = float(src["e_read_pJ_per_B"])
        args.sram_e_write = float(src["e_write_pJ_per_B"])
        args.sram_t_read  = float(src.get("t_read_ns", args.sram_t_read))
        args.sram_t_write = float(src.get("t_write_ns", args.sram_t_write))
        args.sram_leak    = float(src["leakage_mW_per_bank"])

    if args.run and not args.cfg:
        print("--run requires --cfg", file=sys.stderr)
        sys.exit(2)
    if not args.run and not args.infile:
        print("Provide an input CSV or use --run with --cfg", file=sys.stderr)
        sys.exit(2)

    # Metadata from cfg (if provided)
    cfg = parse_cfg(args.cfg) if args.cfg else {}
    line_bytes = (cfg.get("word_width_bits") // 8) if cfg.get("word_width_bits") else None
    process_nm = cfg.get("process_nm")
    tech = cfg.get("device")
    op_temp_C = (cfg.get("temp_K") - 273.15) if cfg.get("temp_K") is not None else None
    capacity_MB = (cfg.get("capacity_B") / (1024*1024)) if cfg.get("capacity_B") else None
    memcorner = cfg.get("memcell_file") or "NVM"
    corner_id = f"{memcorner}_{tech or 'TECH'}_{process_nm or 'PNM'}nm_{(int(op_temp_C) if op_temp_C is not None else 'TEMP')}C"

    # If requested, run NVSim once and pick up its CSV
    infile = args.infile
    if args.run:
        csv_path = run_nvsim_and_get_csv(args.nvsim_bin, args.cfg, prefix_hint=cfg.get("output_prefix"))
        if not csv_path:
            sys.exit(1)
        infile = csv_path

    # Output header (single-run; no sweep columns)
    cols = [
        "area_mm2","area_total_mm2",
        "read_lat_ns","write_lat_ns","read_E_pJ","write_E_pJ","leakage_mW","tRC_ns",
        "read_E_pJ_per_B_raw","write_E_pJ_per_B_raw",
        "read_E_pJ_per_payload_B","write_E_pJ_per_payload_B",
        "process_nm","tech","op_temp_C","line_bytes","banks","nvm_corner_id",
        "cap_effective_Bps","cap_effective_payload_Bps","e_link_pJ_per_B","P_retention_mW",
        "capacity_raw_MB","capacity_payload_MB",
        "Ew_endurance_scaled_pJ","tw_endurance_scaled_ns","endurance_cycles",
        "ecc_area_frac","ecc_energy_frac",
    ]
    print(",".join(cols))
    first_pack = None

    with open(infile, 'r', encoding='utf-8') as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            r = parse_nvsim_row(raw)   # <-- no kwargs anymore
            if not r:
                continue

            # ECC payload ratio
            payload_ratio = 1.0 / (1.0 + args.ecc_alpha) if args.ecc_alpha > 0 else 1.0

            # energies per byte (need line_bytes)
            if not line_bytes or line_bytes <= 0:
                read_pJ_per_B_raw = math.nan
                write_pJ_per_B_raw = math.nan
                read_pJ_per_payload_B = math.nan
                write_pJ_per_payload_B = math.nan
            else:
                read_pJ_per_B_raw  = r["read_E_pJ"]  / line_bytes
                write_pJ_per_B_raw = r["write_E_pJ"] / line_bytes
                logic_scale = (1.0 + args.ecc_energy_frac_logic)
                ecc_expand  = (1.0 + args.ecc_alpha)
                read_pJ_per_payload_B  = read_pJ_per_B_raw  * ecc_expand * logic_scale
                write_pJ_per_payload_B = write_pJ_per_B_raw * ecc_expand * logic_scale

            # link energy per payload byte (w/ optional ECC on link)
            e_link = 8.0 * args.link_pj_per_bit * (1.0 + (args.ecc_alpha if args.ecc_on_link else 0.0))

            # capacity caps (NVM vs D2D)
            if line_bytes and r["read_lat_ns"] and r["read_lat_ns"] > 0:
                per_bank_Bps = line_bytes / (r["read_lat_ns"] * 1e-9)
            else:
                per_bank_Bps = math.nan
            cap_nvm = args.nvm_headroom * args.banks * per_bank_Bps if not math.isnan(per_bank_Bps) else math.nan
            cap_d2d = args.d2d_cap_GBs * 1e9
            cap_d2d_payload = cap_d2d / (1.0 + args.ecc_alpha) if args.ecc_on_link else cap_d2d
            cap_effective = min(cap_nvm, cap_d2d) if (not math.isnan(cap_nvm)) else cap_d2d
            cap_effective_payload = min(cap_nvm, cap_d2d_payload) if (not math.isnan(cap_nvm)) else cap_d2d_payload

            # retention background power (separate term)
            if capacity_MB:
                P_retention_W = (args.retention_E_pJ_per_MB * 1e-12 * capacity_MB / max(args.retention_T_s, 1e-30)) * args.retention_temp_factor
                P_retention_mW = P_retention_W * 1e3
            else:
                P_retention_mW = math.nan

            # endurance scaled
            Ew_scaled = r["write_E_pJ"] * args.endurance_write_factor
            tw_scaled = r["write_lat_ns"] * args.endurance_time_factor

            # area with ECC metadata overhead
            area_total = r["area_mm2"] * (1.0 + args.ecc_area_frac)

            cap_raw_MB = capacity_MB if capacity_MB is not None else math.nan
            cap_pay_MB = (capacity_MB * payload_ratio) if capacity_MB is not None else math.nan

            # choose energy flavor for device pack
            e_read_sel  = read_pJ_per_payload_B  if args.energies_from == "payload" else read_pJ_per_B_raw
            e_write_sel = write_pJ_per_payload_B if args.energies_from == "payload" else write_pJ_per_B_raw

            if first_pack is None and all(not math.isnan(v) for v in [e_read_sel, e_write_sel,
                                                                       r["read_lat_ns"], r["write_lat_ns"], r["leakage_mW"]]):
                first_pack = {
                    "e_read": e_read_sel,
                    "e_write": e_write_sel,
                    "t_read_ns": r["read_lat_ns"],
                    "t_write_ns": r["write_lat_ns"],
                    "leakage_mW": r["leakage_mW"],
                }

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
                f"{corner_id}",
                f"{cap_effective}",
                f"{cap_effective_payload}",
                f"{e_link}",
                f"{P_retention_mW}",
                f"{cap_raw_MB}",
                f"{cap_pay_MB}",
                f"{Ew_scaled}",
                f"{tw_scaled}",
                f"{args.endurance_cycles}",
                f"{args.ecc_area_frac}",
                f"{args.ecc_energy_frac_logic}",
            ]
            print(",".join(row))

    # Emit device pack if requested
    if args.emit_device_pack:
        if first_pack is None:
            print("[nvsim_post] cannot emit device pack: no valid row parsed (missing line_bytes or NaNs).",
                  file=sys.stderr)
        else:
            write_device_pack(args.emit_device_pack, first_pack, args, cfg)

if __name__ == "__main__":
    main()