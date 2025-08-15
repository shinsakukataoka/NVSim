#!/usr/bin/env bash
set -euo pipefail

# 1) typedef.h — add TransistorFlavor before #endif (idempotent)
if ! grep -q 'enum TransistorFlavor' typedef.h; then
  awk 'BEGIN{added=0}
       /#endif/ && !added {
         print "enum TransistorFlavor { planar = 0, finfet = 1 };";
         added=1
       }
       { print }' typedef.h > typedef.h.new && mv typedef.h.new typedef.h
fi

# 2) InputParameter.h — add fields before class closing brace (idempotent)
if ! grep -q 'transistorFlavor' InputParameter.h; then
  awk 'BEGIN{done=0}
       /};/ && !done {
         print "    TransistorFlavor transistorFlavor;  /* Planar vs FinFET */";
         print "    bool enableRetention;               /* Enable retention/refresh modeling */";
         done=1
       }
       { print }' InputParameter.h > InputParameter.h.new && mv InputParameter.h.new InputParameter.h
fi

# 3) InputParameter.cpp — constructor defaults (idempotent)
if ! grep -q 'transistorFlavor = ' InputParameter.cpp; then
  awk '{
        print
      }
      /cacheAccessMode = normal_access_mode;/ && !done_ctor {
        print "\n\ttransistorFlavor = planar;";
        print "\tenableRetention = false;";
        done_ctor=1
      }' InputParameter.cpp > InputParameter.cpp.new && mv InputParameter.cpp.new InputParameter.cpp
fi

# 4) InputParameter.cpp — parse -TransistorFlavor and -EnableRetention (idempotent)
if ! grep -q 'TransistorFlavor' InputParameter.cpp; then
  awk 'BEGIN{inserted=0}
       /-WriteScheme/ && !inserted {
         print "        if (!strncmp(\"-TransistorFlavor\", line, strlen(\"-TransistorFlavor\"))) {";
         print "            sscanf(line, \"-TransistorFlavor: %s\", tmp);";
         print "            if (!strcmp(tmp, \"FinFET\") || !strcmp(tmp, \"FINFET\") || !strcmp(tmp, \"finfet\"))";
         print "                transistorFlavor = finfet;";
         print "            else";
         print "                transistorFlavor = planar;";
         print "            continue;";
         print "        }";
         print "        if (!strncmp(\"-EnableRetention\", line, strlen(\"-EnableRetention\"))) {";
         print "            sscanf(line, \"-EnableRetention: %s\", tmp);";
         print "            if (!strcmp(tmp, \"Yes\") || !strcmp(tmp, \"yes\") || !strcmp(tmp, \"True\") || !strcmp(tmp, \"true\"))";
         print "                enableRetention = true;";
         print "            else";
         print "                enableRetention = false;";
         print "            continue;";
         print "        }";
         inserted=1
       }
       { print }' InputParameter.cpp > InputParameter.cpp.new && mv InputParameter.cpp.new InputParameter.cpp
fi

# 5) MemCell.h — add retentionTime field after wordlineBoostRatio (idempotent)
if ! grep -q 'retentionTime' MemCell.h; then
  awk 'BEGIN{done=0}
       /wordlineBoostRatio/ && !done {
         print;
         print "        double retentionTime;   /* Retention time for dynamic/leaky cells (s); <=0 means ignore */";
         done=1;
         next
       }
       { print }' MemCell.h > MemCell.h.new && mv MemCell.h.new MemCell.h
fi

# 6) MemCell.cpp — ctor default for retentionTime (idempotent)
if ! grep -q 'retentionTime = ' MemCell.cpp; then
  awk '{
        print
      }
      /wordlineBoostRatio/ && !done_ctor {
        print "\tretentionTime       = 0;";
        done_ctor=1
      }' MemCell.cpp > MemCell.cpp.new && mv MemCell.cpp.new MemCell.cpp
fi

# 7) MemCell.cpp — parse -RetentionTime (idempotent)
if ! grep -q 'RetentionTime (s)' MemCell.cpp; then
  awk 'BEGIN{inserted=0}
       /-ResetMode/ && !inserted {
         print "        if (!strncmp(\"-RetentionTime\", line, strlen(\"-RetentionTime\"))) {";
         print "            sscanf(line, \"-RetentionTime (s): %lf\", &retentionTime);";
         print "            continue;";
         print "        }";
         inserted=1
       }
       { print }' MemCell.cpp > MemCell.cpp.new && mv MemCell.cpp.new MemCell.cpp
fi

# 8) SubArray.cpp — apply FinFET cap bump after WL/BL wire caps computed (idempotent)
if ! grep -q 'FinFET modeling tweak' SubArray.cpp; then
  awk '{
         print
       }
       /resBitline = lenBitline \* localWire->resWirePerUnit;/ && !done {
         print "\t/* FinFET modeling tweak: slightly higher effective fringe/gate cap at same F */";
         print "\tif (inputParameter->transistorFlavor == finfet) {";
         print "\t\tcapWordline *= 1.12;";  # visible bump
         print "\t\tcapBitline  *= 1.08;";
         print "\t}";
         done=1
       }' SubArray.cpp > SubArray.cpp.new && mv SubArray.cpp.new SubArray.cpp
fi

echo "Patch applied. Now rebuild: make clean && make -j"
