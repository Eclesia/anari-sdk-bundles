#!/bin/bash
# Photon device (https://github.com/mvictoras/photon), a Kokkos path tracer, with the Kokkos CUDA
# backend. Kokkos compiles for one GPU architecture : the CUDA kernels also embed its PTX, which
# the driver compiles for newer GPUs.
#
# Photon fetches its dependencies with CMake's FetchContent : they are fetched here instead and
# given to FetchContent, so the build step works offline and is cached like the other parts.
# - ANARI SDK : Photon pins a release, the ANARI SDK of the other parts is used instead, so the
#   device matches the libanari of the bundle. Photon compiles some ANARI SDK files itself, found
#   in FetchContent's default folder : the paths are changed to the folder given to FetchContent.
# - Kokkos and the OIDN binary release : the versions Photon pins.
#
#   build-photon.sh fetch [photon ref] [ANARI SDK ref]
#   build-photon.sh build [jobs] [Kokkos architecture, for example PASCAL61]
#   build-photon.sh bundle
source /scripts/common.sh
src="${SRC}/photon"
ANARI_SRC="${SRC}/anari-photon"
KOKKOS_SRC="${SRC}/kokkos"
OIDN_ROOT=/opt/oidn-photon

case "${1:-}" in
fetch)
    clone https://github.com/mvictoras/photon.git "${src}" "${2:-}"
    deps="${src}/cmake/Dependencies.cmake"

    # ANARI SDK of the bundle, patched like Photon's FetchContent does to be built as a subproject
    clone https://github.com/KhronosGroup/ANARI-SDK.git "${ANARI_SRC}" "${3:-}"
    find "${ANARI_SRC}" -name CMakeLists.txt -exec sed -i 's/CMAKE_SOURCE_DIR/PROJECT_SOURCE_DIR/g' {} +
    find "${src}" -name CMakeLists.txt -exec sed -i 's#${CMAKE_BINARY_DIR}/_deps/anari-src#${anari_SOURCE_DIR}#g' {} +
    if grep -rq '_deps/anari-src' --include=CMakeLists.txt "${src}"; then
        echo "Photon still refers to _deps/anari-src, update build-photon.sh" >&2
        exit 1
    fi
    # Photon is developed with MSVC : /U (undefine a macro) is read by GCC as an input file, -U works with both
    find "${src}" -name CMakeLists.txt -exec sed -i 's#"/UKOKKOS_ENABLE_CUDA"#"-UKOKKOS_ENABLE_CUDA"#g' {} +

    # Kokkos, at the tag pinned by Photon
    kokkos=$(sed -n '/FetchContent_Declare(/,/)/p' "${deps}" | sed -n '/kokkos.git/,/GIT_TAG/p' | sed -nE 's/.*GIT_TAG +([^ )]+).*/\1/p' | head -1)
    test -n "${kokkos}" || { echo "Kokkos tag not found in ${deps}" >&2; exit 1; }
    clone https://github.com/kokkos/kokkos.git "${KOKKOS_SRC}" "${kokkos}"

    # OIDN binary release, at the version pinned by Photon
    oidn=$(sed -nE 's/.*set\(OIDN_VERSION "([^"]+)"\).*/\1/p' "${deps}" | head -1)
    test -n "${oidn}" || { echo "OIDN version not found in ${deps}" >&2; exit 1; }
    mkdir -p "${OIDN_ROOT}"
    wget -q -O /tmp/oidn.tar.gz \
        "https://github.com/RenderKit/oidn/releases/download/v${oidn}/oidn-${oidn}.x86_64.linux.tar.gz"
    tar -xzf /tmp/oidn.tar.gz -C "${OIDN_ROOT}" --strip-components=1
    rm /tmp/oidn.tar.gz
    test -f "${OIDN_ROOT}/include/OpenImageDenoise/oidn.hpp" || { echo "Unexpected OIDN archive layout" >&2; exit 1; }
    echo "oidn ${oidn} binary release" >> "${PREFIX}/MANIFEST.txt"
    ;;
build)
    arch="${3:-PASCAL61}"
    # CUDA architecture number of the Kokkos architecture, for example 61 for PASCAL61
    cuda_arch=$(echo "${arch}" | sed -nE 's/^[A-Z]+([0-9]+)$/\1/p')
    test -n "${cuda_arch}" || { echo "Unexpected Kokkos architecture ${arch}" >&2; exit 1; }
    cmake -S "${src}" -B "${src}/build" "${cmake_common[@]}" \
        -DOPENCODE_ENABLE_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${cuda_arch}" \
        -DKokkos_ARCH_${arch}=ON \
        -DPHOTON_ENABLE_EMBREE=OFF \
        -DPHOTON_ENABLE_OPTIX=OFF \
        -DPHOTON_ENABLE_OIDN=ON \
        -DOpenImageDenoise_DIR="${OIDN_ROOT}/lib/cmake/OpenImageDenoise-$(ls "${OIDN_ROOT}/lib/cmake" | sed -nE 's/^OpenImageDenoise-(.*)$/\1/p' | head -1)" \
        -DFETCHCONTENT_SOURCE_DIR_KOKKOS="${KOKKOS_SRC}" \
        -DFETCHCONTENT_SOURCE_DIR_ANARI="${ANARI_SRC}" \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON
    cmake --build "${src}/build" -j "$(jobs "${2:-}")" --target anari_library_photon
    device=$(find "${src}/build" -name 'libanari_library_photon.so*' -type f | head -1)
    test -n "${device}" || { echo "libanari_library_photon.so not found in ${src}/build" >&2; exit 1; }
    mkdir -p "${PREFIX}/lib"
    cp "${device}" "${PREFIX}/lib/libanari_library_photon.so"
    # shared libraries of the build folder (a cache mount, not kept in the image), libanari excepted :
    # the bundle uses the one of the sdk part
    find "${src}/build" -name 'lib*.so*' ! -name 'libanari*' ! -name 'libanari_library_*' \
        \( -type f -o -type l \) -exec cp -a {} "${PREFIX}/lib/" \;
    echo "Kokkos architecture ${arch}" >> "${PREFIX}/MANIFEST.txt"
    ;;
bundle)
    # the OIDN devices (CPU, CUDA, ...) are opened with dlopen : seeds
    bash /scripts/collect-part.sh \
        -p "${OIDN_ROOT}/lib" \
        -l photon="${src}" \
        -l kokkos="${KOKKOS_SRC}" \
        -l oidn="${OIDN_ROOT}:2" \
        "${PREFIX}/lib/libanari_library_photon.so" \
        "${OIDN_ROOT}/lib/libOpenImageDenoise*.so*"
    ;;
*) usage ;;
esac
