#!/bin/bash
echo "Run NVSim"
python3 tools/nvsim_post.py --run \
  --cfg src/sample_NVM_macro.cfg \
  --nvsim_bin "$(pwd)/src/nvsim" \
  --emit-device-pack out/device_from_nvsim.json \
  --ecc_alpha 0.125 --ecc_area_frac 0.12 --ecc_energy_frac_logic 0.03 \
  --endurance_cycles 1e9 \
  > out/enriched.csv