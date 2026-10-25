#!/bin/bash

# Builds the homestar device trees with the cameras described
# (sc7180-trogdor-homestar-camera.dtsi) from a kernel source tree.
#
#   camera/build-dtbs.sh <linux source dir> <output dir>

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$1" && pwd)
out=$2
dts=$src/arch/arm64/boot/dts/qcom

mkdir -p "$out"
for board in "$dts"/sc7180-trogdor-homestar-r*.dts; do
  name=$(basename "$board" .dts)
  {
    echo "#include \"$board\""
    echo "#include \"$here/sc7180-trogdor-homestar-camera.dtsi\""
  } >"$out/$name.dts"
  cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ \
    -I "$dts" -I "$src/include" -I "$src/scripts/dtc/include-prefixes" \
    "$out/$name.dts" -o "$out/$name.dts.pp"
  dtc -I dts -O dtb -q -o "$out/$name.dtb" "$out/$name.dts.pp"
  rm "$out/$name.dts" "$out/$name.dts.pp"
  echo "$out/$name.dtb"
done
