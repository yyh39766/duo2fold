#!/bin/sh
# 用法: ./build.sh
# 注意: 在 rootful / rootless 之间切换时必须先 make clean
set -e
cd "$(dirname "$0")"
make clean
make package
echo "==> 产物: ./packages/*.deb"
