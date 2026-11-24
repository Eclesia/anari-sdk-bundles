#!/bin/bash
# Gather the libraries of one bundle part in /bundle/${PART} : the given device libraries and every
# library they need, with an $ORIGIN search path so they find each other without LD_LIBRARY_PATH.
# build-bundle.sh merges the parts into the bundle.
#
# usage : collect-part.sh [-p search_dir]... [-l name=dir[:depth]]... seed...
#   -p    directory searched for the dependencies, in addition to ${PREFIX}/lib
#   -l    copy the license files found in dir (to the given depth, 1 by default) to licenses/name
#   seed  file, glob pattern or directory copied to lib/ (a directory holds data loaded next to
#         the libraries, like the Cycles kernels)
#
# Libraries provided by every Linux system or by the GPU driver are not copied :
# glibc, libstdc++, libgcc, OpenGL/EGL (libglvnd), Vulkan, X11/xcb/Wayland, CUDA driver, OptiX.
# libanari is only copied by the sdk part, the device parts use it.
source /scripts/common.sh
PART=${PART:?PART must be set to the bundle part name}

OUT=/bundle/${PART}
LIB=${OUT}/lib
rm -rf "${OUT}"
mkdir -p "${LIB}" "${OUT}/licenses"

SEARCH_PATH="${PREFIX}/lib"
licenses=()
while getopts "p:l:" opt; do
    case "${opt}" in
        p) SEARCH_PATH="${SEARCH_PATH}:${OPTARG}" ;;
        l) licenses+=("${OPTARG}") ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))

SYSTEM_LIBS='^(linux-vdso|ld-linux|libc\.so|libm\.so|libmvec\.so|libdl\.so|libpthread\.so|librt\.so|libutil\.so|libresolv\.so|libnsl\.so|libcrypt\.so|libgcc_s\.so|libstdc\+\+\.so|libatomic\.so|libGL|libEGL|libGLX|libGLdispatch|libOpenGL|libGLES|libvulkan|libcuda\.so|libnvidia|libnvoptix|libX|libxcb|libxkbcommon|libdrm|libgbm|libwayland|libz\.so|libexpat|libffi|libselinux|libpcre|libuuid|libblkid|libmount|libsystemd|libudev|libdbus|libgcrypt|libgpg-error|liblzma|libbz2|libcap)'

excluded() {
    [[ "$1" =~ ${SYSTEM_LIBS} ]] && return 0
    [ "${PART}" != sdk ] && [[ "$1" == libanari.so* ]] && return 0
    return 1
}

#----------------------------------------------------------------------------------------
# 1. Seeds, kept with their original names : some are loaded with dlopen by name
#----------------------------------------------------------------------------------------
shopt -s nullglob
for seed in "$@"; do
    matches=( ${seed} )
    if [ ${#matches[@]} -eq 0 ]; then
        echo "Nothing matches ${seed}" >&2
        exit 1
    fi
    for m in "${matches[@]}"; do
        cp -a "${m}" "${LIB}/"
        #a link to a library outside the seeds : copy its file too
        if [ -L "${m}" ] && [ ! -d "${m}" ]; then
            cp -an "$(readlink -f "${m}")" "${LIB}/"
        fi
    done
done
shopt -u nullglob

#----------------------------------------------------------------------------------------
# 2. Dependencies, found with ldd, repeated until nothing new is found
#----------------------------------------------------------------------------------------
version_of() {
    # version numbers of a library real file name, for comparison
    basename "$(readlink -f "$1")" | sed -E 's/^[^.]*\.so\.?//'
}

add_dependency() {
    # copied under its real file name with a soname link, so its full version stays known
    local soname="$1" path="$2"
    local target="${LIB}/${soname}"
    local real
    real=$(readlink -f "${path}")
    if [ -e "${target}" ]; then
        [ "$(readlink -f "${target}")" = "${real}" ] && return 1
        # same library from two components (TBB, OIDN, Embree...) : keep the newest
        local current newer
        current=$(version_of "${target}")
        newer=$(printf '%s\n%s\n' "${current}" "$(version_of "${path}")" | sort -V | tail -1)
        if [ "${newer}" = "${current}" ]; then return 1; fi
        echo "  replace ${soname} ${current} by ${newer}"
        rm -f "$(readlink -f "${target}")" "${target}"
    fi
    cp "${real}" "${LIB}/$(basename "${real}")"
    added+=("${real}")
    chmod u+w "${LIB}/$(basename "${real}")"
    [ "$(basename "${real}")" = "${soname}" ] || ln -sf "$(basename "${real}")" "${target}"
    return 0
}

added=()
changed=1
while [ ${changed} -eq 1 ]; do
    changed=0
    while IFS= read -r -d '' elf; do
        while read -r soname arrow path _; do
            [ "${arrow}" = "=>" ] || continue
            excluded "${soname}" && continue
            if [ "${path}" = "not" ]; then
                echo "  missing ${soname} needed by $(basename "${elf}")"
                continue
            fi
            if add_dependency "${soname}" "${path}"; then
                echo "  add ${soname} from ${path}"
                changed=1
            fi
        done < <(LD_LIBRARY_PATH="${LIB}:${SEARCH_PATH}" ldd "${elf}" 2>/dev/null || true)
    done < <(find "${LIB}" -maxdepth 1 -type f -name '*.so*' -print0)
done

#----------------------------------------------------------------------------------------
# 3. Search path relative to each library, also used by dlopen from libanari
#----------------------------------------------------------------------------------------
find "${LIB}" -maxdepth 1 -type f -name '*.so*' -print0 | while IFS= read -r -d '' elf; do
    if file -L "${elf}" | grep -q 'ELF'; then
        patchelf --force-rpath --set-rpath '$ORIGIN' "${elf}" || echo "  could not patch $(basename "${elf}")"
        # glibc 2.41 and newer refuse to load a library requiring an executable stack, usually
        # an object missing its stack note rather than code really needing it
        if readelf -lW "${elf}" | grep GNU_STACK | grep -q RWE; then
            if patchelf --clear-execstack "${elf}" 2>/dev/null; then
                echo "  WARNING $(basename "${elf}") required an executable stack, cleared"
            else
                echo "  WARNING $(basename "${elf}") requires an executable stack, glibc 2.41 and newer will not load it"
            fi
        fi
    fi
done

#----------------------------------------------------------------------------------------
# 4. Licenses and manifest
#----------------------------------------------------------------------------------------
for entry in "${licenses[@]}"; do
    name="${entry%%=*}"
    spec="${entry#*=}"
    dir="${spec%%:*}"
    depth=1
    [ "${spec}" != "${dir}" ] && depth="${spec##*:}"
    [ -d "${dir}" ] || continue
    mkdir -p "${OUT}/licenses/${name}"
    find "${dir}/" -maxdepth "${depth}" -type f \
        \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname '*third-party*' \) \
        -exec cp {} "${OUT}/licenses/${name}/" \; 2>/dev/null || true
done
# libraries copied from a system package (libc++ of the halogen part, libgomp...) : the license
# files of that package, found with dpkg (Ubuntu) or rpm (Rocky Linux). The other libraries are
# not owned by a package : the query fails (rpm then prints "file ... is not owned by any package"
# on its standard output) and the library is skipped. A missing license never fails the build.
for file in "${added[@]}"; do
    if command -v dpkg-query > /dev/null; then
        owner=$(dpkg-query -S "${file}" 2> /dev/null) || continue
        pkg=$(head -1 <<< "${owner}" | cut -d: -f1)
        [ -n "${pkg}" ] && [ -f "/usr/share/doc/${pkg}/copyright" ] || continue
        mkdir -p "${OUT}/licenses/${pkg}"
        cp "/usr/share/doc/${pkg}/copyright" "${OUT}/licenses/${pkg}/" || true
    elif command -v rpm > /dev/null; then
        owner=$(rpm -qf --queryformat '%{NAME}\n' "${file}" 2> /dev/null) || continue
        pkg=$(head -1 <<< "${owner}")
        [ -n "${pkg}" ] || continue
        files=$(rpm -qL "${pkg}" 2> /dev/null) || continue
        while read -r f; do
            [ -f "${f}" ] || continue
            mkdir -p "${OUT}/licenses/${pkg}"
            cp "${f}" "${OUT}/licenses/${pkg}/" || true
        done <<< "${files}"
    fi
done
find "${OUT}/licenses" -mindepth 1 -type d -empty -delete

{
    echo "Built : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Base  : $(grep PRETTY_NAME /etc/os-release | cut -d= -f2), $(ldd --version | head -1)"
    if command -v nvcc > /dev/null; then echo "CUDA  : $(nvcc --version | grep release)"; fi
    echo "Components (name commit source) :"
    cat "${PREFIX}/MANIFEST.txt"
} > "${OUT}/MANIFEST.txt"

#----------------------------------------------------------------------------------------
# 5. Check : every device must resolve its dependencies from the part, libanari from the sdk part
#----------------------------------------------------------------------------------------
echo "Dependency check of part ${PART} (libraries of the system or the driver are expected to be missing) :"
for device in "${LIB}"/libanari_library_*.so; do
    missing=$(env -u LD_LIBRARY_PATH ldd "${device}" 2>/dev/null | awk '/not found/ {print $1}' \
              | while read -r name; do excluded "${name}" || echo "${name}"; done)
    if [ -n "${missing}" ]; then
        echo "  $(basename "${device}") MISSING : ${missing//$'\n'/ }"
    else
        echo "  $(basename "${device}") ok"
    fi
done
du -sh "${OUT}"
