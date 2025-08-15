#!/usr/bin/env bash
set -euo pipefail

must_exist() { for f in "$@"; do [[ -f "$f" ]] || { echo "Missing $f"; exit 1; }; done; }
in_repo_root() { must_exist "Makefile" "typedef.h" "MemCell.h" "MemCell.cpp" "InputParameter.h" "InputParameter.cpp" "SubArray.cpp"; }
bk() { cp -n "$1" "$1.bak" || true; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Need '$1' on PATH"; exit 1; }; }

main() {
  need_cmd perl
  in_repo_root

  echo "Backing up originals (*.bak)…"
  for f in MemCell.h MemCell.cpp InputParameter.h InputParameter.cpp typedef.h SubArray.cpp; do bk "$f"; done

  # --- typedef.h: add TransistorFlavor enum -----------------------------------
  if ! grep -q 'enum TransistorFlavor' typedef.h; then
    perl -0777 -i -pe 's/(enum DeviceRoadmap\s*\{[^}]+\};\s*)/$1

enum TransistorFlavor
{
\tPlanar,
\tFinFET
};

/s' typedef.h
    echo "typedef.h: added enum TransistorFlavor { Planar, FinFET }"
  else
    echo "typedef.h: TransistorFlavor already present (skipping)"
  fi

  # --- MemCell.h: add retentionTime field -------------------------------------
  if ! grep -q 'retentionTime' MemCell.h; then
    perl -0777 -i -pe 's/(wordlineBoostRatio[^\n]*\n)/$1\tdouble retentionTime;   \/* Retention time for dynamic\/leaky cells (s); <=0 means ignore *\/\n/s' MemCell.h
    echo "MemCell.h: added double retentionTime;"
  else
    echo "MemCell.h: retentionTime already present (skipping)"
  fi

  # --- MemCell.cpp: init + parser for -RetentionTime --------------------------
  if ! grep -q 'retentionTime' MemCell.cpp; then
    # Initialize in constructor (after minSenseVoltage = 0.08;)
    perl -0777 -i -pe 's/(minSenseVoltage\s*=\s*0\.08;\s*\n)/$1\tretentionTime        = 0;\n/s' MemCell.cpp || {
      echo "WARN: could not auto-initialize retentionTime in MemCell ctor; please add manually"; }
  fi
  # Parser block (after -MinSenseVoltage handling)
  if ! grep -q 'RetentionTime (s)' MemCell.cpp; then
    perl -0777 -i -pe 's/(\n\s*if\s*\(!strncmp\("-MinSenseVoltage",.*?continue;\s*\n\s*\}\s*\n)/$1\t\tif (!strncmp("-RetentionTime", line, strlen("-RetentionTime"))) {\n\t\t\tsscanf(line, "-RetentionTime (s): %lf", &retentionTime);\n\t\t\tcontinue;\n\t\t}\n\n/s' MemCell.cpp
    echo "MemCell.cpp: added -RetentionTime (s) parser and default init"
  else
    echo "MemCell.cpp: retentionTime parser already present (skipping)"
  fi

  # --- InputParameter.h: add flags --------------------------------------------
  if ! grep -q 'enableRetention' InputParameter.h; then
    perl -0777 -i -pe 's/(bool useCactiAssumption;[^\n]*\n)/$1\tbool enableRetention;\n\tTransistorFlavor transistorFlavor;\n/s' InputParameter.h
    echo "InputParameter.h: added enableRetention + transistorFlavor"
  else
    echo "InputParameter.h: fields already present (skipping)"
  fi

  # --- InputParameter.cpp: defaults in ctor -----------------------------------
  if ! grep -q 'enableRetention' InputParameter.cpp; then
    perl -0777 -i -pe 's/(useCactiAssumption\s*=\s*false;\s*\n)/$1\tenableRetention = false;\n\ttransistorFlavor = Planar;\n/s' InputParameter.cpp
    echo "InputParameter.cpp: set defaults (enableRetention=false, transistorFlavor=Planar)"
  else
    echo "InputParameter.cpp: defaults already present (skipping)"
  fi

  # --- InputParameter.cpp: parser for -EnableRetention / -TransistorFlavor ----
  if ! grep -q 'TransistorFlavor' InputParameter.cpp; then
    perl -0777 -i -pe 's/(\n\s*if\s*\(!strncmp\("-InternalSensing", line, strlen\("-InternalSensing"\)\)\)\s*\{)/\n\t\tif (!strncmp("-EnableRetention", line, strlen("-EnableRetention"))) {\n\t\t\tsscanf(line, "-EnableRetention: %s", tmp);\n\t\t\tenableRetention = (!strcmp(tmp, "Yes") || !strcmp(tmp, "True") || !strcmp(tmp, "Enable") || !strcmp(tmp, "YES") || !strcmp(tmp, "TRUE"));\n\t\t\tcontinue;\n\t\t}\n\t\tif (!strncmp("-TransistorFlavor", line, strlen("-TransistorFlavor"))) {\n\t\t\tsscanf(line, "-TransistorFlavor: %s", tmp);\n\t\t\tif (!strcmp(tmp, "FinFET") || !strcmp(tmp, "FINFET"))\n\t\t\t\ttransistorFlavor = FinFET;\n\t\t\telse\n\t\t\t\ttransistorFlavor = Planar;\n\t\t\tcontinue;\n\t\t}\n$1/s' InputParameter.cpp
    echo "InputParameter.cpp: added -EnableRetention and -TransistorFlavor parsers"
  else
    echo "InputParameter.cpp: parsers already present (skipping)"
  fi

  # --- SubArray.cpp: coarse FinFET WL-cap bump (10%) --------------------------
  if ! grep -q 'FinFET capacitance correction' SubArray.cpp; then
    perl -0777 -i -pe 's/(\/\* Initialize sub-component \*\/)/\/\* FinFET capacitance correction (coarse): increase WL cap by ~10% to reflect higher effective gate\/fringe caps in fins *\/\n\tif (inputParameter->transistorFlavor == FinFET) {\n\t\tcapWordline *= 1.10;\n\t}\n\n$1/s' SubArray.cpp
    echo "SubArray.cpp: inserted coarse FinFET WL capacitance bump"
  else
    echo "SubArray.cpp: FinFET bump already present (skipping)"
  fi

  echo "Done. Now rebuild with:  make"
  echo
  echo "New config knobs you can use:"
  cat <<'CFG'
  # In *.cell (memcell file)
  -RetentionTime (s): 0.050

  # In *.cfg (top-level)
  -EnableRetention: Yes
  -TransistorFlavor: FinFET   # or Planar
CFG
}

main "$@"
