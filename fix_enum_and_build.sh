set -euo pipefail

# 1) Ensure enum TransistorFlavor is defined in typedef.h (inside the include guard)
if ! grep -q 'enum TransistorFlavor' typedef.h; then
  awk 'BEGIN{done=0}
       {
         if ($0 ~ /^#endif/ && !done) {
           print "enum TransistorFlavor { planar = 0, finfet = 1 };"
           done=1
         }
         print
       }' typedef.h > typedef.h.new && mv typedef.h.new typedef.h
fi

# 2) (Optional safety) If SubArray.cpp didn’t see typedef.h, include it explicitly
if ! grep -q 'typedef.h' SubArray.cpp; then
  awk '{
         print
       }
       NR==1{
         # no-op; we will insert after the first project include
       }' SubArray.cpp > /dev/null
  awk 'BEGIN{ins=0}
       {
         print
         if (!ins && $0 ~ /#include "SubArray.h"/) {
           print "#include \"typedef.h\""
           ins=1
         }
       }' SubArray.cpp > SubArray.cpp.new && mv SubArray.cpp.new SubArray.cpp
fi

# 3) Rebuild
make clean
make -j
