#!/usr/bin/env python3
"""Builds the ANARI native bundle for Windows x86_64.

    python build.py part <part>                 build one part in dist/parts/<part>
    python build.py assemble <name> <part>...   merge the parts in dist/<name> and dist/<name>.zip

Parts:
    sdk      anari.dll, helide, helide_gpu, halcyon, debug, sink
    ospray   ospray (anari-ospray and the OSPRay binary release)
    visrtx   visrtx (CUDA / OptiX) and visgl (OpenGL, WGL)
    halogen  halogen (Google's Filament engine)

Runs in a Visual Studio developer environment (cl, link and dumpbin on the PATH) with CMake,
Ninja, git and Python 3.9 or newer. The visrtx part also needs the CUDA toolkit (nvcc on the PATH).
The options are environment variables, with the names of the Linux build arguments:
JOBS, ANARI_SDK_REF, ISPC_VERSION, GLSLANG_REF, SDL3_REF, OSPRAY_VERSION, ANARI_OSPRAY_REF,
VISRTX_REF, VISRTX_MIN_ARCH, HALOGEN_REF. An empty *_REF is the default branch.

Every DLL of a part is in its bin/ folder: libanari loads a device by its full path with
LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, so the libraries next to the device are found without PATH.
"""
import argparse
import datetime
import filecmp
import glob
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

PARTS = ["sdk", "ospray", "visrtx", "halogen"]
HERE = Path(__file__).resolve().parent

# Libraries of Windows or of the GPU driver, never shipped
DRIVER_DLLS = {"nvcuda.dll", "nvml.dll", "nvoptix.dll", "nvapi64.dll", "vulkan-1.dll", "opengl32.dll"}
# Microsoft Visual C++ runtime, shipped: users may not have the redistributable installed
VC_RUNTIME = re.compile(r"^(vcruntime140(_1)?|msvcp140(_1|_2|_atomic_wait|_codecvt_ids)?|concrt140|vcomp140)\.dll$")

PART = ""
WORK = Path()
SRC = Path()
PREFIX = Path()
OPT = Path()
DIST = HERE / "dist"
MANIFEST = []


#----------------------------------------------------------------------------------------
# Helpers
#----------------------------------------------------------------------------------------
def opt(name, default=""):
    """Option given as environment variable, the default when unset or empty."""
    return os.environ.get(name) or default


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def jobs():
    return opt("JOBS", str(os.cpu_count() or 2))


def posix(path):
    return Path(path).as_posix()


def run(cmd, cwd=None, capture=False):
    cmd = [str(c) for c in cmd]
    print("+ " + " ".join(cmd), flush=True)
    if capture:
        return subprocess.run(cmd, cwd=cwd, check=True, stdout=subprocess.PIPE, text=True).stdout
    subprocess.run(cmd, cwd=cwd, check=True)
    return None


def rmtree(path):
    def writable(func, p, _):
        os.chmod(p, 0o700)
        func(p)
    if Path(path).exists():
        shutil.rmtree(path, onerror=writable)


def clone(url, dest, ref=""):
    """Clones a repository at a branch or tag, the default branch when the ref is empty.
    An existing clone is reused. The commit is recorded in the manifest."""
    if dest.exists():
        print(f"Reusing {dest}")
    else:
        cmd = ["git", "clone", "--depth", "1", "--recurse-submodules", "--shallow-submodules"]
        if ref:
            cmd += ["--branch", ref]
        run(cmd + [url, dest])
    commit = run(["git", "-C", dest, "rev-parse", "HEAD"], capture=True).strip()
    MANIFEST.append(f"{dest.name} {commit} {url}")


def fetch_archive(url, dest):
    """Downloads and extracts a zip or tar archive in dest, without its top folder."""
    downloads = WORK / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / url.rsplit("/", 1)[1]
    if not archive.exists():
        print(f"Downloading {url}", flush=True)
        urllib.request.urlretrieve(url, archive)
    tmp = dest.with_name(dest.name + ".tmp")
    rmtree(tmp)
    tmp.mkdir(parents=True)
    if archive.name.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            z.extractall(tmp)
    else:
        with tarfile.open(archive) as t:
            if hasattr(tarfile, "data_filter"):
                t.extractall(tmp, filter="tar")
            else:
                t.extractall(tmp)
    entries = list(tmp.iterdir())
    top = entries[0] if len(entries) == 1 and entries[0].is_dir() else tmp
    rmtree(dest)
    shutil.move(str(top), str(dest))
    rmtree(tmp)


def cmake_configure(src, *args, build=None):
    build = build or src / "build"
    run(["cmake", "-S", src, "-B", build, "-G", "Ninja",
         "-DCMAKE_BUILD_TYPE=Release",
         f"-DCMAKE_INSTALL_PREFIX={posix(PREFIX)}",
         "-DCMAKE_INSTALL_LIBDIR=lib",
         f"-DCMAKE_PREFIX_PATH={posix(PREFIX)}",
         *args])
    return build


def cmake_build(src, *args):
    """Configures, compiles and installs a CMake project in PREFIX (later -D options win)."""
    build = cmake_configure(src, *args)
    run(["cmake", "--build", build, "-j", jobs()])
    run(["cmake", "--install", build])


#----------------------------------------------------------------------------------------
# Components
#----------------------------------------------------------------------------------------
def anari_core():
    """libanari alone, to link the devices of the other parts with. Not shipped."""
    src = SRC / "ANARI-SDK"
    clone("https://github.com/KhronosGroup/ANARI-SDK.git", src, opt("ANARI_SDK_REF"))
    cmake_build(src,
                "-DBUILD_SHARED_LIBS=ON", "-DBUILD_TESTING=OFF", "-DBUILD_EXAMPLES=OFF",
                "-DBUILD_VIEWER=OFF", "-DBUILD_CTS=OFF",
                "-DBUILD_HELIDE_DEVICE=OFF", "-DBUILD_HELIDE_GPU_DEVICE=OFF",
                "-DBUILD_HALCYON_DEVICE=OFF", "-DBUILD_DEBUG_DEVICE=OFF", "-DBUILD_SINK_DEVICE=OFF")


def part_sdk():
    # ISPC, for halcyon
    version = opt("ISPC_VERSION", "1.28.2")
    ispc = OPT / "ispc"
    fetch_archive(f"https://github.com/ispc/ispc/releases/download/v{version}/ispc-v{version}-windows.zip", ispc)
    run([ispc / "bin" / "ispc.exe", "--version"])

    # glslang, to compile the helide_gpu shaders. Not shipped.
    glslang = OPT / "glslang"
    clone("https://github.com/KhronosGroup/glslang.git", SRC / "glslang", opt("GLSLANG_REF", "16.6.0"))
    cmake_build(SRC / "glslang",
                f"-DCMAKE_INSTALL_PREFIX={posix(glslang)}",
                "-DENABLE_OPT=OFF", "-DGLSLANG_TESTS=OFF",
                "-DENABLE_GLSLANG_BINARIES=ON", "-DBUILD_SHARED_LIBS=OFF")

    # SDL3 (SDL_gpu), for helide_gpu, which loads it at first use (delay-loaded DLL)
    clone("https://github.com/libsdl-org/SDL.git", SRC / "SDL", opt("SDL3_REF", "release-3.4.20"))
    cmake_build(SRC / "SDL",
                "-DSDL_SHARED=ON", "-DSDL_STATIC=OFF", "-DSDL_TEST_LIBRARY=OFF",
                "-DSDL_TESTS=OFF", "-DSDL_EXAMPLES=OFF", "-DSDL_GPU=ON", "-DSDL_VULKAN=ON")

    # ANARI SDK. Embree is built from source (static, internal tasking), like on Linux.
    src = SRC / "ANARI-SDK"
    clone("https://github.com/KhronosGroup/ANARI-SDK.git", src, opt("ANARI_SDK_REF"))
    cmake_build(src,
                "-DBUILD_SHARED_LIBS=ON", "-DBUILD_TESTING=OFF", "-DBUILD_EXAMPLES=OFF",
                "-DBUILD_VIEWER=OFF", "-DBUILD_CTS=OFF",
                "-DBUILD_HELIDE_DEVICE=ON",
                "-DBUILD_HELIDE_GPU_DEVICE=ON",
                f"-DGLSLANG_VALIDATOR={posix(glslang / 'bin' / 'glslangValidator.exe')}",
                "-DGLM_BUILD_LIBRARY=OFF",
                "-DBUILD_HALCYON_DEVICE=ON",
                f"-DCMAKE_ISPC_COMPILER={posix(ispc / 'bin' / 'ispc.exe')}",
                "-DCMAKE_DISABLE_FIND_PACKAGE_embree=ON",
                "-DCMAKE_DISABLE_FIND_PACKAGE_Imath=ON",
                "-DBUILD_DEBUG_DEVICE=ON", "-DBUILD_SINK_DEVICE=ON")

    collect([PREFIX / "bin" / "anari*.dll", PREFIX / "bin" / "SDL3.dll"],
            licenses={"anari-sdk": (src, 1), "sdl3": (SRC / "SDL", 1)})


def part_ospray():
    version = opt("OSPRAY_VERSION", "3.2.0")
    ospray = OPT / "ospray"
    fetch_archive(f"https://github.com/RenderKit/ospray/releases/download/v{version}/"
                  f"ospray-{version}.x86_64.windows.zip", ospray)
    MANIFEST.append(f"ospray {version} binary release")
    anari_core()
    src = SRC / "anari-ospray"
    clone("https://github.com/ospray/anari-ospray.git", src, opt("ANARI_OSPRAY_REF"))
    config = sorted(glob.glob(str(ospray / "lib" / "cmake" / "ospray-*")))
    if not config:
        sys.exit(f"No OSPRay CMake package in {ospray}")
    cmake_build(src,
                f"-DCMAKE_PREFIX_PATH={posix(PREFIX)};{posix(ospray)}",
                f"-Dospray_DIR={posix(config[0])}")
    # all the OSPRay libraries : OSPRay loads its modules, Open VKL and OIDN their devices, by name
    collect([PREFIX / "bin" / "anari_library_ospray.dll", ospray / "bin" / "*.dll"],
            search=[ospray / "bin"],
            licenses={"anari-ospray": (src, 1), "ospray": (ospray, 3)})


def part_visrtx():
    anari_core()
    src = SRC / "VisRTX"
    clone("https://github.com/NVIDIA/VisRTX.git", src, opt("VISRTX_REF"))
    args = []
    if opt("VISRTX_MIN_ARCH"):
        args.append(f"-DVISRTX_MIN_ARCH={opt('VISRTX_MIN_ARCH')}")
    # The OptiX shaders are not precompiled : it needs a GPU
    cmake_build(src,
                "-DVISRTX_BUILD_RTX_DEVICE=ON", "-DVISRTX_BUILD_GL_DEVICE=ON",
                "-DVISRTX_BUILD_TSD=OFF", "-DVISRTX_BUILD_TESTS=OFF",
                "-DVISRTX_PRECOMPILE_SHADERS=OFF", *args)
    # the CUDA runtime DLLs VisRTX links to are shipped, with the CUDA license
    cuda = os.environ.get("CUDA_PATH")
    licenses = {"visrtx": (src, 1)}
    if cuda:
        licenses["cuda"] = (Path(cuda), 1)
    collect([PREFIX / "bin" / "anari_library_visrtx.dll", PREFIX / "bin" / "anari_library_visgl.dll"],
            search=[Path(cuda) / "bin"] if cuda else [],
            licenses=licenses)


def part_halogen():
    """Halogen builds with its own ANARI SDK submodule and downloads the Filament release it pins.
    It has no install rule : the device library is copied from the build folder."""
    src = SRC / "Halogen"
    clone("https://github.com/MetaversalCorp/Halogen.git", src, opt("HALOGEN_REF"))
    cmakelists = (src / "CMakeLists.txt").read_text(encoding="utf-8")
    version = re.search(r'set\(FILAMENT_VERSION "([^"]+)"', cmakelists)
    if version:
        MANIFEST.append(f"filament {version.group(1)} binary release")
    # Same changes as the Linux build (linux/scripts/build-halogen.sh) : no -Werror, which
    # stops the build on warnings of newer compilers, and no LightManager::Builder::global(),
    # which no released Filament version has
    patch_lines(src / "src" / "CMakeLists.txt", ":-Werror>")
    patch_lines(src / "src" / "Light.cpp", ".global(global)")
    if re.search(r"Builder::global|\.global\(", (src / "src" / "Light.cpp").read_text(encoding="utf-8")):
        sys.exit("Light.cpp still uses LightManager::Builder::global, update build.py")
    build = cmake_configure(src, "-DBUILD_TESTS=OFF")
    run(["cmake", "--build", build, "-j", jobs(), "--target", "anari_library_halogen"])
    devices = sorted(build.rglob("anari_library_halogen.dll"))
    if not devices:
        sys.exit(f"anari_library_halogen.dll not found in {build}")
    (PREFIX / "bin").mkdir(parents=True, exist_ok=True)
    shutil.copy2(devices[0], PREFIX / "bin")
    collect([PREFIX / "bin" / "anari_library_halogen.dll"],
            search=[devices[0].parent],
            licenses={"halogen": (src, 1), "filament": (src / "external" / "filament", 1)})


def patch_lines(path, text):
    """Removes the lines containing the given text."""
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    path.write_text("".join(l for l in lines if text not in l), encoding="utf-8")


#----------------------------------------------------------------------------------------
# Collection : the seeds and every DLL they need, in dist/parts/<part>/bin
#----------------------------------------------------------------------------------------
def dependencies(dll):
    """Names of the DLLs a DLL imports, delay-loaded ones included, read with dumpbin."""
    out = run(["dumpbin", "/nologo", "/dependents", dll], capture=True)
    names = []
    listing = False
    for line in out.splitlines():
        line = line.strip()
        if line.endswith("dependencies:"):
            listing = True
        elif line == "Summary":
            listing = False
        elif listing and line.lower().endswith(".dll"):
            names.append(line)
    return names


def excluded(name):
    lower = name.lower()
    if VC_RUNTIME.match(lower):
        return False
    if lower.startswith(("api-ms-", "ext-ms-")) or lower in DRIVER_DLLS:
        return True
    if PART != "sdk" and lower == "anari.dll":
        return True
    system32 = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32"
    return (system32 / name).exists()


def vc_redist_dirs():
    redist = os.environ.get("VCToolsRedistDir")
    if not redist:
        return []
    dirs = glob.glob(os.path.join(redist, "x64", "Microsoft.VC*.CRT"))
    dirs += glob.glob(os.path.join(redist, "x64", "Microsoft.VC*.OpenMP"))
    return [Path(d) for d in dirs]


def find(name, dirs):
    for d in dirs:
        candidate = Path(d) / name
        if candidate.is_file():
            return candidate
    return None


def unresolved(bindir):
    """Device -> imported DLLs found neither in bindir nor in the system."""
    present = {f.name.lower() for f in bindir.iterdir()}
    result = {}
    for device in sorted(bindir.glob("anari_library_*.dll")):
        result[device.name] = [d for d in dependencies(device)
                               if not excluded(d) and d.lower() not in present]
    return result


def collect(seeds, search=(), licenses=None):
    out = DIST / "parts" / PART
    bindir = out / "bin"
    rmtree(out)
    bindir.mkdir(parents=True)
    (out / "licenses").mkdir()

    # 1. seeds, with their names : some are loaded by name
    for pattern in seeds:
        matches = glob.glob(str(pattern))
        if not matches:
            sys.exit(f"Nothing matches {pattern}")
        for m in matches:
            if Path(m).is_dir():
                shutil.copytree(m, bindir / Path(m).name)
            else:
                shutil.copy2(m, bindir)

    # 2. dependencies, repeated until nothing new is found
    dirs = [bindir, PREFIX / "bin", *search, *vc_redist_dirs()]
    changed = True
    while changed:
        changed = False
        present = {f.name.lower() for f in bindir.iterdir()}
        for dll in sorted(bindir.glob("*.dll")):
            for dep in dependencies(dll):
                if excluded(dep) or dep.lower() in present:
                    continue
                found = find(dep, dirs)
                if found is None:
                    print(f"  missing {dep} needed by {dll.name}")
                    continue
                print(f"  add {dep} from {found}")
                shutil.copy2(found, bindir / dep)
                present.add(dep.lower())
                changed = True

    # 3. licenses and manifest
    for name, (directory, depth) in (licenses or {}).items():
        copy_licenses(Path(directory), depth, out / "licenses" / name)
    base = f"Windows {platform.version()}, MSVC {os.environ.get('VCToolsVersion', 'unknown')}"
    lines = [f"Built : {now()}", f"Base  : {base}"]
    if shutil.which("nvcc"):
        release = [l for l in run(["nvcc", "--version"], capture=True).splitlines() if "release" in l]
        if release:
            lines.append(f"CUDA  : {release[0].strip()}")
    lines.append("Components (name commit source) :")
    (out / "MANIFEST.txt").write_text("\n".join(lines + MANIFEST) + "\n", encoding="utf-8")

    # 4. check
    print(f"Dependency check of part {PART} :")
    check(bindir)


def copy_licenses(directory, depth, dest):
    if not directory.is_dir():
        return
    pattern = re.compile(r"^(licen[cs]e|copying|notice|eula).*|.*third-party.*", re.IGNORECASE)
    base = len(directory.parts)
    for root, dirs, files in os.walk(directory):
        level = len(Path(root).parts) - base
        if level >= depth - 1:
            dirs[:] = []
        if level >= depth:
            continue
        for f in files:
            if pattern.match(f):
                dest.mkdir(parents=True, exist_ok=True)
                shutil.copy2(Path(root) / f, dest / f)


def check(bindir):
    """Prints, for each device, the DLLs not found and whether Windows loads it like libanari
    does (full path, dependencies searched next to it). Devices needing the NVIDIA driver do not
    load on a machine without it."""
    for device, missing in unresolved(bindir).items():
        status = "ok" if not missing else "MISSING : " + " ".join(missing)
        load = subprocess.run([sys.executable, "-c", "import ctypes, sys; ctypes.CDLL(sys.argv[1])",
                               str(bindir / device)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        error = load.stdout.strip().splitlines() or ["unknown error"]
        loaded = "loads" if load.returncode == 0 else "does not load here : " + error[-1]
        print(f"  {device} {status}, {loaded}")


#----------------------------------------------------------------------------------------
# Bundle : the parts merged
#----------------------------------------------------------------------------------------
def assemble(name, parts):
    out = DIST / name
    rmtree(out)
    archive = DIST / (name + ".zip")
    if archive.exists():
        archive.unlink()
    bindir = out / "bin"
    (bindir / "licenses").mkdir(parents=True)
    origin = {}
    for part in parts:
        src = DIST / "parts" / part
        if not (src / "bin").is_dir():
            sys.exit(f"Part {part} not found in {DIST / 'parts'}")
        print(f"Merging part {part}")
        for f in sorted((src / "bin").iterdir()):
            key = f.name.lower()
            if key not in origin:
                if f.is_dir():
                    shutil.copytree(f, bindir / f.name)
                else:
                    shutil.copy2(f, bindir)
                origin[key] = (part, f.name)
            elif f.is_file() and not filecmp.cmp(f, bindir / origin[key][1], shallow=False):
                first = origin[key][0]
                print(f"  {f.name} differs in parts {first} and {part} : the one of {first} is kept")
        shutil.copytree(src / "licenses", bindir / "licenses", dirs_exist_ok=True)

    devices = sorted(re.sub(r"^anari_library_(.*)\.dll$", r"\1", f.name) for f in bindir.glob("anari_library_*.dll"))
    lines = ["ANARI native bundle"]
    if os.environ.get("BUNDLE_VERSION"):
        lines.append(f"Version : {os.environ['BUNDLE_VERSION']}")
    lines += [f"Assembled : {now()}", "", "Devices :"]
    lines += [f"  {d}" for d in devices]
    for part in parts:
        lines += ["", f"[{part}]", (DIST / "parts" / part / "MANIFEST.txt").read_text(encoding="utf-8").rstrip()]
    (out / "MANIFEST.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out / "README.txt").write_text("""libanari is bin\\anari.dll. The devices are next to it (bin\\anari_library_<name>.dll),
where anariLoadLibrary("<name>") finds them.

All the libraries are in bin\\ : libanari loads the devices by their full path, and Windows finds
the libraries they need next to them. PATH does not need to be changed.
visrtx needs an NVIDIA driver supporting CUDA 12.4 or newer, visgl OpenGL,
helide_gpu a Vulkan or Direct3D 12 driver.
See MANIFEST.txt for the component versions and bin\\licenses\\ for their licenses.
""", encoding="utf-8")

    print()
    print("Dependency check on this machine :")
    check(bindir)
    shutil.make_archive(str(DIST / name), "zip", root_dir=DIST, base_dir=name)
    print(f"Bundle : {out}")
    print(f"Archive : {archive} ({archive.stat().st_size // (1024 * 1024)} MB)")


#----------------------------------------------------------------------------------------
def main():
    global PART, WORK, SRC, PREFIX, OPT, DIST
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dist", type=Path, default=HERE / "dist", help="output folder (default: dist)")
    parser.add_argument("--work", type=Path,
                        default=Path(os.environ["RUNNER_TEMP"]) / "w" if os.environ.get("RUNNER_TEMP") else HERE / "work",
                        help="sources and build folders, keep it short (default: work)")
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("part", help="build one part")
    p.add_argument("part", choices=PARTS)
    a = commands.add_parser("assemble", help="merge parts into the bundle")
    a.add_argument("name")
    a.add_argument("parts", nargs="+")
    args = parser.parse_args()

    DIST = args.dist.resolve()
    if args.command == "assemble":
        assemble(args.name, args.parts)
        return
    PART = args.part
    WORK = args.work.resolve() / PART
    SRC = WORK / "src"
    PREFIX = WORK / "install"
    OPT = WORK / "opt"
    for d in (SRC, PREFIX, OPT):
        d.mkdir(parents=True, exist_ok=True)
    globals()["part_" + PART]()


if __name__ == "__main__":
    main()
