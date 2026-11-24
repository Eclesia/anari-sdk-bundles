#!/bin/bash
# Viskores device (https://github.com/Viskores/viskores, viskores/rendering/anari-device), the
# successor of VTK-m. The device is a module of Viskores, built with the modules it needs only :
# the ANARI group (the device and the interop library) and its dependencies (cont, worklet,
# rendering...), as shared libraries. Viskores runs its worklets with OpenMP, and optionally with
# CUDA, the backend being chosen at runtime.
#
# Built without logging : the device initializes Viskores when loaded, which installs the signal
# handlers of its logging library (loguru). They replace the signal handlers of the host process.
#
#   build-viskores.sh fetch [viskores ref]
#   build-viskores.sh build [jobs] [CUDA architectures, for example "61;86", empty for OpenMP only]
#   build-viskores.sh bundle
source /scripts/common.sh
src="${SRC}/viskores"

case "${1:-}" in
fetch)
    clone https://github.com/Viskores/viskores.git "${src}" "${2:-}"
    ;;
build)
    cuda=()
    if [ -n "${3:-}" ]; then
        cuda=(-DViskores_ENABLE_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$3" -DCMAKE_CUDA_HOST_COMPILER="${CUDAHOSTCXX}")
    fi
    cmake_build "${src}" "${2:-}" \
        -DBUILD_SHARED_LIBS=ON \
        -DViskores_BUILD_ALL_LIBRARIES=OFF \
        -DViskores_ENABLE_RENDERING=ON \
        -DViskores_ENABLE_ANARI=ON \
        -DViskores_ENABLE_OPENMP=ON \
        -DViskores_ENABLE_TESTING=OFF \
        -DViskores_ENABLE_BENCHMARKS=OFF \
        -DViskores_ENABLE_EXAMPLES=OFF \
        -DViskores_ENABLE_TUTORIALS=OFF \
        -DViskores_ENABLE_DOCUMENTATION=OFF \
        -DViskores_ENABLE_PYTHON_BINDINGS=OFF \
        -DViskores_ENABLE_MPI=OFF \
        -DViskores_ENABLE_DEVELOPER_FLAGS=OFF \
        -DViskores_ENABLE_LOGGING=OFF \
        "${cuda[@]}"
    if [ -n "${3:-}" ]; then echo "Viskores CUDA architectures $3" >> "${PREFIX}/MANIFEST.txt"; fi
    ;;
bundle)
    # the OpenMP runtime (libgomp) is the one of the system, under the GCC runtime library exception
    third="${src}/viskores/thirdparty"
    bash /scripts/collect-part.sh \
        -l viskores="${src}" \
        -l gcc-runtime=/usr/share/licenses/gcc \
        -l viskores-diy="${third}/diy/viskoresdiy" \
        -l viskores-lcl="${third}/lcl/viskoreslcl" \
        -l viskores-lodepng="${third}/lodepng/viskoreslodepng" \
        "${PREFIX}/lib/libanari_library_viskores*.so*"
    ;;
*) usage ;;
esac
