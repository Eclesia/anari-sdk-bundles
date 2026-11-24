#!/bin/bash
# Blender Cycles device (anari-cycles), built with Blender's precompiled libraries
# (OpenImageIO, OpenColorIO, OpenEXR, OIDN, TBB...), which are built for glibc 2.28 like this image.
source /scripts/common.sh
libs="${SRC}/anari-cycles/cycles/lib/linux_x64"

case "${1:-}" in
fetch)
    clone https://github.com/jeffamstutz/anari-cycles.git "${SRC}/anari-cycles" "${2:-}"
    ;;
libraries)
    # precompiled libraries of the Cycles version used by anari-cycles (several GB, git LFS)
    (cd "${SRC}/anari-cycles/cycles" && python3 src/cmake/make_update.py --no-cycles)
    test -d "${libs}/openimageio" || { echo "Blender precompiled libraries not found in ${libs}"; exit 1; }
    ;;
build)
    # git lfs leaves small text pointers instead of the libraries when the download fails
    if ! file -L "${libs}"/openimageio/lib/libOpenImageIO.so* | grep -q ELF; then
        echo "Blender precompiled libraries are git LFS pointers, not libraries : the LFS download failed"
        exit 1
    fi
    # anari-cycles looks for OpenImageIO and OpenColorIO before Cycles configures the precompiled
    # libraries : search all of them like Cycles does (except mesa and dpcpp, see external_libs.cmake)
    prefixPath="${PREFIX}"
    for d in "${libs}"/*/; do
        case "$(basename "${d}")" in mesa|dpcpp) continue ;; esac
        prefixPath="${prefixPath};${d%/}"
    done
    cmake_build "${SRC}/anari-cycles" "${2:-}" \
        -DCMAKE_PREFIX_PATH="${prefixPath}" \
        -DWITH_LIBS_PRECOMPILED=ON \
        -DANARI_CYCLES_USE_OIDN=ON \
        -DOPENIMAGEDENOISE_ROOT_DIR="${libs}/openimagedenoise" \
        -DANARI_CYCLES_USE_OPTIX="${3}" \
        -DANARI_CYCLES_CUDA_ARCHS="${4}" \
        -DCMAKE_CUDA_HOST_COMPILER="${CUDAHOSTCXX}"
    ;;
bundle)
    # the kernels installed next to the plugin, the OIDN device modules OIDN loads by name
    args=()
    for d in "${libs}"/*/; do
        name=$(basename "${d}")
        case "${name}" in mesa|dpcpp) continue ;; esac
        [ -d "${d}lib" ] && args+=(-p "${d}lib")
        args+=(-l "blender-libs/${name}=${d%/}:2")
    done
    seeds=("${PREFIX}/lib/libanari_library_cycles.so")
    # kernels only exist with CYCLES_OPTIX=ON
    [ -d "${PREFIX}/lib/cycles" ] && seeds+=("${PREFIX}/lib/cycles")
    compgen -G "${libs}/openimagedenoise/lib/libOpenImageDenoise_device_*.so*" > /dev/null \
        && seeds+=("${libs}/openimagedenoise/lib/libOpenImageDenoise_device_*.so*")
    bash /scripts/collect-part.sh "${args[@]}" \
        -l anari-cycles="${SRC}/anari-cycles" \
        -l cycles="${SRC}/anari-cycles/cycles" \
        "${seeds[@]}"
    ;;
*) usage ;;
esac
