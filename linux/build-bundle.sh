#!/bin/bash
# Builds the ANARI native bundle with one container image per part, and assembles it in dist/.
#
#   ./build-bundle.sh                       build the parts not built yet, then assemble
#   ./build-bundle.sh sdk halogen           rebuild these parts (and the ones not built yet)
#   ./build-bundle.sh --only sdk halogen    build only these parts, the parts not built yet are left out
#   ./build-bundle.sh all                   rebuild every part
#   ./build-bundle.sh cycles -- --build-arg CYCLES_OPTIX=OFF --build-arg JOBS=8
#
# Parts :
#   sdk      libanari, helide, helide_gpu, halcyon, debug, sink   (Dockerfile.sdk)
#   ospray   ospray                                                (Dockerfile.ospray)
#   visrtx   visrtx, visgl                                         (Dockerfile.visrtx)
#   cycles   cycles                                                (Dockerfile.cycles)
#   halogen  halogen, needs glibc 2.39 or newer                    (Dockerfile.halogen)
#   webgpu   webgpu (anari-webgpu with Dawn and Slang)             (Dockerfile.webgpu)
#   photon   photon (Kokkos path tracer, CUDA)                     (Dockerfile.photon)
#   barney   barney (NVIDIA multi-GPU path tracer, OptiX)          (Dockerfile.barney)
#   viskores viskores (Viskores worklets, OpenMP)                  (Dockerfile.viskores)
# All parts except halogen are built from a shared toolchain image (Dockerfile.toolchain).
#
# Arguments after -- are given to every "docker build". Uses podman when docker is not installed,
# or the command in the CONTAINER environment variable.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
engine=${CONTAINER:-$(command -v docker || command -v podman || true)}
if [ -z "${engine}" ]; then
    echo "docker or podman is required" >&2
    exit 1
fi

PARTS=(sdk ospray visrtx cycles halogen webgpu photon barney viskores)
TOOLCHAIN=anari-bundle-toolchain
NAME=anari-linux-x86_64
dist="${here}/dist"
log="${here}/build.log"

image_of() { echo "anari-bundle-$1"; }
exists() { "${engine}" image inspect "$1" > /dev/null 2>&1; }

#----------------------------------------------------------------------------------------
# Arguments
#----------------------------------------------------------------------------------------
requested=()
extra=()
only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; extra=("$@"); break ;;
        --only) only=1 ;;
        all) requested=("${PARTS[@]}") ;;
        *)
            if [[ " ${PARTS[*]} " != *" $1 "* ]]; then
                echo "Unknown part $1, expected one of : all ${PARTS[*]}" >&2
                exit 2
            fi
            requested+=("$1") ;;
    esac
    shift
done

to_build=()
for part in "${PARTS[@]}"; do
    if [[ " ${requested[*]} " == *" ${part} "* ]] || { [ ${only} -eq 0 ] && ! exists "$(image_of "${part}")"; }; then
        to_build+=("${part}")
    fi
done

#----------------------------------------------------------------------------------------
# Images
#----------------------------------------------------------------------------------------
: > "${log}"
echo "Build log : ${log}"

build_image() {
    local image="$1" file="$2"
    echo "=== Building ${image} (${file})" | tee -a "${log}"
    "${engine}" build -t "${image}" -f "${here}/${file}" \
        --build-arg TOOLCHAIN_IMAGE="${TOOLCHAIN}" "${extra[@]}" "${here}" 2>&1 | tee -a "${log}"
}

failed=()
needs_toolchain=0
for part in "${to_build[@]}"; do
    [ "${part}" != halogen ] && needs_toolchain=1
done
if [ ${needs_toolchain} -eq 1 ]; then
    #cheap when nothing changed : every layer comes from the cache
    if ! build_image "${TOOLCHAIN}" Dockerfile.toolchain; then
        echo "Toolchain image failed, see ${log}" >&2
        exit 1
    fi
fi
for part in "${to_build[@]}"; do
    if ! build_image "$(image_of "${part}")" "Dockerfile.${part}"; then
        echo "Part ${part} failed, see ${log}" >&2
        failed+=("${part}")
    fi
done

#----------------------------------------------------------------------------------------
# Parts, copied from the images to dist/parts
#----------------------------------------------------------------------------------------
available=()
mkdir -p "${dist}/parts"
for part in "${PARTS[@]}"; do
    image=$(image_of "${part}")
    if ! exists "${image}"; then
        if [ -d "${dist}/parts/${part}/lib" ]; then
            echo "Part ${part} has no image, its previous copy in ${dist}/parts is used"
            available+=("${part}")
        else
            echo "Part ${part} is not built, it is not in the bundle"
        fi
        continue
    fi
    rm -rf "${dist}/parts/${part}"
    container=$("${engine}" create "${image}")
    if "${engine}" cp "${container}:/bundle/${part}" "${dist}/parts/"; then
        available+=("${part}")
    else
        echo "Image ${image} has no /bundle/${part}" >&2
        failed+=("${part}")
    fi
    "${engine}" rm -f "${container}" > /dev/null
done
# other folders in dist/parts, for example a previous bundle : merged last, so they only
# provide what the parts above do not have
for d in "${dist}"/parts/*/; do
    name=$(basename "${d}")
    if [[ " ${PARTS[*]} " != *" ${name} "* ]] && [ -d "${d}lib" ]; then
        echo "Extra part ${name} from ${d}"
        available+=("${name}")
    fi
done

#----------------------------------------------------------------------------------------
# Bundle : the parts merged, keeping the newest version of the libraries shared by parts
#----------------------------------------------------------------------------------------
"${here}/assemble-bundle.sh" "${dist}" "${NAME}" "${available[@]}"

if [ ${#failed[@]} -gt 0 ]; then
    echo "Failed parts : ${failed[*]}, see ${log}" >&2
    exit 1
fi
