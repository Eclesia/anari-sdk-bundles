#!/bin/bash
# Barney device (https://github.com/NVIDIA/barney), NVIDIA's (multi-)GPU path tracer. Its OptiX
# headers, OWL, cuBQL and Embree are git submodules. The "barney" library links every backend
# built and selects the best one at runtime : OptiX, and optionally the Embree CPU backend for
# machines without NVIDIA GPU. Built without MPI.
#
#   build-barney.sh fetch [barney ref]
#   build-barney.sh build [jobs] [CUDA architectures, for example "61;86"] [CPU backend ON|OFF]
#   build-barney.sh bundle
source /scripts/common.sh
src="${SRC}/barney"

case "${1:-}" in
fetch)
    clone https://github.com/NVIDIA/barney.git "${src}" "${2:-}"
    ;;
build)
    cmake_build "${src}" "${2:-}" \
        -DBARNEY_BACKEND_OPTIX=ON \
        -DBARNEY_BACKEND_CUDA=OFF \
        -DBARNEY_BACKEND_CPU="${4:-OFF}" \
        -DBARNEY_BACKEND_HIP=OFF \
        -DBARNEY_BACKEND_HIPRT=OFF \
        -DBARNEY_MPI=OFF \
        -DCMAKE_CUDA_ARCHITECTURES="${3:-61}"
    ;;
bundle)
    bash /scripts/collect-part.sh \
        -l barney="${src}" \
        -l owl="${src}/submodules/owl" \
        -l cubql="${src}/submodules/cuBQL" \
        -l optix-dev="${src}/submodules/optix" \
        -l barney-3rdparty="${src}/3rdParty:2" \
        "${PREFIX}/lib/libanari_library_barney*.so*"
    ;;
*) usage ;;
esac
