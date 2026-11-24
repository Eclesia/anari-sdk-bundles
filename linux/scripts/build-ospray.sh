#!/bin/bash
# OSPRay device : the official OSPRay binary release (OSPRay, Embree, Open VKL, OIDN, TBB, rkcommon)
# and the anari-ospray translation layer built against it.
source /scripts/common.sh

case "${1:-}" in
fetch)
    version="$2"
    rm -rf "${OSPRAY_ROOT}"
    mkdir -p "${OSPRAY_ROOT}"
    wget -q -O /tmp/ospray.tar.gz \
        "https://github.com/RenderKit/ospray/releases/download/v${version}/ospray-${version}.x86_64.linux.tar.gz"
    tar -xzf /tmp/ospray.tar.gz -C "${OSPRAY_ROOT}" --strip-components=1
    rm /tmp/ospray.tar.gz
    echo "ospray ${version} binary release" >> "${PREFIX}/MANIFEST.txt"
    clone https://github.com/ospray/anari-ospray.git "${SRC}/anari-ospray" "${3:-}"
    ;;
build)
    cmake_build "${SRC}/anari-ospray" "${2:-}" \
        -DCMAKE_PREFIX_PATH="${PREFIX};${OSPRAY_ROOT}" \
        -Dospray_DIR="$(ls -d "${OSPRAY_ROOT}"/lib/cmake/ospray-*)"
    ;;
bundle)
    # all the OSPRay libraries : OSPRay loads its modules, Open VKL and OIDN their devices, by name
    bash /scripts/collect-part.sh -p "${OSPRAY_ROOT}/lib" \
        -l anari-ospray="${SRC}/anari-ospray" \
        -l ospray="${OSPRAY_ROOT}:3" \
        "${PREFIX}/lib/libanari_library_ospray.so" \
        "${OSPRAY_ROOT}/lib/*.so*"
    ;;
*) usage ;;
esac
