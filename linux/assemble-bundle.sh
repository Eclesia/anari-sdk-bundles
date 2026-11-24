#!/bin/bash
# Merges bundle parts into the bundle, and archives it.
#
#   assemble-bundle.sh <dist> <name> <part>...
#
# Each part is a folder <dist>/parts/<part> holding lib/, licenses/ and MANIFEST.txt, as written
# by collect-part.sh. The parts are merged in the given order : when two parts ship the same
# library (TBB, OIDN, Embree), the newest version is kept, and other files are kept from the first
# part having them. The licenses of the components go to lib/licenses/<component>, next to the
# libraries. The bundle is written to <dist>/<name> and archived to <dist>/<name>.tar.gz.
#
# The BUNDLE_VERSION environment variable, when set, is written in the manifest.
# Used by build-bundle.sh and by the GitHub workflow.
set -euo pipefail

if [ $# -lt 3 ]; then
    echo "usage: $(basename "$0") <dist> <name> <part>..." >&2
    exit 2
fi
dist=$(cd "$1" && pwd)
NAME="$2"
shift 2
parts=("$@")

version_of() {
    basename "$(readlink -f "$1")" | sed -E 's/^[^.]*\.so\.?//'
}

merge_part() {
    local src="$1/lib" dst="$2/lib" f name current candidate newest
    # files and data folders, kept from the first part having them
    for f in "${src}"/*; do
        name=$(basename "${f}")
        [ -L "${f}" ] && continue
        [ -e "${dst}/${name}" ] || cp -a "${f}" "${dst}/"
    done
    # soname links, pointing to the newest version
    for f in "${src}"/*; do
        [ -L "${f}" ] || continue
        name=$(basename "${f}")
        if [ -L "${dst}/${name}" ] || [ -e "${dst}/${name}" ]; then
            current=$(version_of "${dst}/${name}")
            candidate=$(version_of "${f}")
            newest=$(printf '%s\n%s\n' "${current}" "${candidate}" | sort -V | tail -1)
            [ "${newest}" = "${current}" ] && continue
            echo "  ${name} : ${current} replaced by ${candidate} from $(basename "$1")"
            rm -f "${dst}/${name}"
        fi
        ln -s "$(readlink "${f}")" "${dst}/${name}"
    done
}

out="${dist}/${NAME}"
rm -rf "${out}" "${dist}/${NAME}.tar.gz"
mkdir -p "${out}/lib/licenses"
for part in "${parts[@]}"; do
    if [ ! -d "${dist}/parts/${part}/lib" ]; then
        echo "Part ${part} not found in ${dist}/parts" >&2
        exit 1
    fi
    echo "Merging part ${part}"
    merge_part "${dist}/parts/${part}" "${out}"
    cp -a "${dist}/parts/${part}/licenses/." "${out}/lib/licenses/"
done

{
    echo "ANARI native bundle"
    if [ -n "${BUNDLE_VERSION:-}" ]; then echo "Version : ${BUNDLE_VERSION}"; fi
    echo "Assembled : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "Devices :"
    ls "${out}/lib" | sed -nE 's/^libanari_library_(.*)\.so$/  \1/p'
    for part in "${parts[@]}"; do
        echo
        echo "[${part}]"
        cat "${dist}/parts/${part}/MANIFEST.txt"
    done
} > "${out}/MANIFEST.txt"

cat > "${out}/README.txt" <<EOF
libanari is lib/libanari.so. The devices are next to it (lib/libanari_library_<name>.so),
where anariLoadLibrary("<name>") finds them.

Libraries find each other through their \$ORIGIN search path, LD_LIBRARY_PATH is not needed.
GPU devices (visrtx, cycles with OptiX) need an NVIDIA driver supporting CUDA 12.6 or newer.
visgl needs OpenGL with EGL, helide_gpu Vulkan and a display (X11 or Wayland), webgpu Vulkan.
photon and barney need an NVIDIA GPU (Pascal or newer, CUDA 12.6 or newer driver).
halogen needs glibc 2.39 or newer (Ubuntu 24.04, Fedora 40, Debian 13 and newer).
See MANIFEST.txt for the component versions and lib/licenses/ for their licenses.
EOF

#----------------------------------------------------------------------------------------
# Check on this machine : every device must find its libraries in the bundle or the system.
# Libraries of the GPU driver are reported missing on a machine without that driver.
#----------------------------------------------------------------------------------------
echo
echo "Dependency check on this machine :"
for device in "${out}"/lib/libanari_library_*.so; do
    missing=$(env -u LD_LIBRARY_PATH ldd "${device}" 2>&1 | awk '/not found/ {print $1}' | sort -u | tr '\n' ' ')
    if [ -n "${missing}" ]; then
        echo "  $(basename "${device}") MISSING : ${missing}"
    else
        echo "  $(basename "${device}") ok"
    fi
done

tar -C "${dist}" -czf "${dist}/${NAME}.tar.gz" "${NAME}"
echo
du -sh "${out}" "${dist}/${NAME}.tar.gz"
echo "Bundle : ${out}"
