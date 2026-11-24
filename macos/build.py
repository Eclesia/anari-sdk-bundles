#!/usr/bin/env python3
"""Builds the ANARI native bundle for macOS arm64 (Apple silicon).

    python3 build.py part <part>                 build one part in dist/parts/<part>
    python3 build.py assemble <name> <part>...   merge the parts in dist/<name> and dist/<name>.tar.gz

Parts:
    sdk       libanari, helide, helide_gpu (SDL_gpu, Metal), halcyon, debug, sink
    ospray    ospray (anari-ospray and the OSPRay binary release)
    halogen   halogen (Google's Filament engine)
    viskores  viskores (Viskores worklets, OpenMP)

Needs the Xcode command line tools, CMake, Ninja, git and Python 3.9 or newer, and from Homebrew:
spirv-cross (sdk part) and libomp (viskores part). The options are environment variables, with
the names of the Linux build arguments: JOBS, ANARI_SDK_REF, ISPC_VERSION, GLSLANG_REF, SDL3_REF,
OSPRAY_VERSION, ANARI_OSPRAY_REF, HALOGEN_REF, VISKORES_REF, and MACOS_DEPLOYMENT_TARGET (oldest
macOS version, 14.0 by default). An empty *_REF is the default branch.

Every library of a part is in its lib/ folder. Each library refers to the others as @rpath/<name>
with the search path @loader_path, so they find each other without DYLD_LIBRARY_PATH. The modified
libraries are signed again with an ad hoc signature, which Apple silicon requires.
"""
import argparse
import datetime
import filecmp
import glob
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

PARTS = ["sdk", "ospray", "halogen", "viskores"]
HERE = Path(__file__).resolve().parent

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


def run(cmd, cwd=None, capture=False, quiet=False):
    cmd = [str(c) for c in cmd]
    if not quiet:
        print("+ " + " ".join(cmd), flush=True)
    if capture:
        return subprocess.run(cmd, cwd=cwd, check=True, stdout=subprocess.PIPE, text=True).stdout
    subprocess.run(cmd, cwd=cwd, check=True)
    return None


def rmtree(path):
    if Path(path).is_symlink():
        Path(path).unlink()
    elif Path(path).exists():
        shutil.rmtree(path)


def brew_prefix(formula):
    return Path(run(["brew", "--prefix", formula], capture=True).strip())


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
    """Downloads and extracts a zip or tar archive in dest, without its top folder.
    unzip is used rather than Python's zipfile, which does not restore symbolic links."""
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
        run(["unzip", "-q", archive, "-d", tmp])
    else:
        run(["tar", "-xf", archive, "-C", tmp])
    entries = [e for e in tmp.iterdir() if e.name != "__MACOSX"]
    top = entries[0] if len(entries) == 1 and entries[0].is_dir() else tmp
    rmtree(dest)
    shutil.move(str(top), str(dest))
    rmtree(tmp)


def cmake_configure(src, *args, build=None):
    build = build or src / "build"
    run(["cmake", "-S", src, "-B", build, "-G", "Ninja",
         "-DCMAKE_BUILD_TYPE=Release",
         f"-DCMAKE_INSTALL_PREFIX={PREFIX}",
         "-DCMAKE_INSTALL_LIBDIR=lib",
         f"-DCMAKE_PREFIX_PATH={PREFIX}",
         f"-DCMAKE_OSX_DEPLOYMENT_TARGET={opt('MACOS_DEPLOYMENT_TARGET', '14.0')}",
         "-DCMAKE_OSX_ARCHITECTURES=arm64",
         *args])
    return build


def cmake_build(src, *args):
    """Configures, compiles and installs a CMake project in PREFIX (later -D options win)."""
    build = cmake_configure(src, *args)
    run(["cmake", "--build", build, "-j", jobs()])
    run(["cmake", "--install", build])


def patch_lines(path, text):
    """Removes the lines containing the given text."""
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    path.write_text("".join(l for l in lines if text not in l), encoding="utf-8")


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
    fetch_archive(f"https://github.com/ispc/ispc/releases/download/v{version}/ispc-v{version}-macOS.arm64.tar.gz", ispc)
    run([ispc / "bin" / "ispc", "--version"])

    # glslang, to compile the helide_gpu shaders, which spirv-cross translates to Metal. Not shipped.
    glslang = OPT / "glslang"
    clone("https://github.com/KhronosGroup/glslang.git", SRC / "glslang", opt("GLSLANG_REF", "16.6.0"))
    cmake_build(SRC / "glslang",
                f"-DCMAKE_INSTALL_PREFIX={glslang}",
                "-DENABLE_OPT=OFF", "-DGLSLANG_TESTS=OFF",
                "-DENABLE_GLSLANG_BINARIES=ON", "-DBUILD_SHARED_LIBS=OFF")
    if not shutil.which("spirv-cross"):
        sys.exit("spirv-cross not found, install it with: brew install spirv-cross")

    # SDL3 (SDL_gpu, Metal backend), for helide_gpu
    clone("https://github.com/libsdl-org/SDL.git", SRC / "SDL", opt("SDL3_REF", "release-3.4.20"))
    cmake_build(SRC / "SDL",
                "-DSDL_SHARED=ON", "-DSDL_STATIC=OFF", "-DSDL_TEST_LIBRARY=OFF",
                "-DSDL_TESTS=OFF", "-DSDL_EXAMPLES=OFF", "-DSDL_GPU=ON")

    # ANARI SDK. Embree is built from source (static, internal tasking), like on Linux.
    src = SRC / "ANARI-SDK"
    clone("https://github.com/KhronosGroup/ANARI-SDK.git", src, opt("ANARI_SDK_REF"))
    cmake_build(src,
                "-DBUILD_SHARED_LIBS=ON", "-DBUILD_TESTING=OFF", "-DBUILD_EXAMPLES=OFF",
                "-DBUILD_VIEWER=OFF", "-DBUILD_CTS=OFF",
                "-DBUILD_HELIDE_DEVICE=ON",
                "-DBUILD_HELIDE_GPU_DEVICE=ON",
                f"-DGLSLANG_VALIDATOR={glslang / 'bin' / 'glslangValidator'}",
                "-DGLM_BUILD_LIBRARY=OFF",
                "-DBUILD_HALCYON_DEVICE=ON",
                f"-DCMAKE_ISPC_COMPILER={ispc / 'bin' / 'ispc'}",
                "-DCMAKE_DISABLE_FIND_PACKAGE_embree=ON",
                "-DCMAKE_DISABLE_FIND_PACKAGE_Imath=ON",
                "-DBUILD_DEBUG_DEVICE=ON", "-DBUILD_SINK_DEVICE=ON")

    # helide_gpu looks up the SDL3 symbols at runtime : SDL3 is a seed
    collect([PREFIX / "lib" / "libanari*.dylib", PREFIX / "lib" / "libSDL3*.dylib"],
            licenses={"anari-sdk": (src, 1), "sdl3": (SRC / "SDL", 1)})


def part_ospray():
    version = opt("OSPRAY_VERSION", "3.2.0")
    ospray = OPT / "ospray"
    fetch_archive(f"https://github.com/RenderKit/ospray/releases/download/v{version}/"
                  f"ospray-{version}.arm64.macosx.zip", ospray)
    MANIFEST.append(f"ospray {version} binary release")
    anari_core()
    src = SRC / "anari-ospray"
    clone("https://github.com/ospray/anari-ospray.git", src, opt("ANARI_OSPRAY_REF"))
    config = sorted(glob.glob(str(ospray / "lib" / "cmake" / "ospray-*")))
    if not config:
        sys.exit(f"No OSPRay CMake package in {ospray}")
    cmake_build(src,
                f"-DCMAKE_PREFIX_PATH={PREFIX};{ospray}",
                f"-Dospray_DIR={config[0]}")
    # all the OSPRay libraries : OSPRay loads its modules, Open VKL and OIDN their devices, by name
    collect([PREFIX / "lib" / "libanari_library_ospray.dylib", ospray / "lib" / "*.dylib"],
            search=[ospray / "lib"],
            licenses={"anari-ospray": (src, 1), "ospray": (ospray, 3)})


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
    devices = sorted(p for p in build.rglob("libanari_library_halogen*.dylib") if not p.is_symlink())
    if not devices:
        sys.exit(f"libanari_library_halogen.dylib not found in {build}")
    (PREFIX / "lib").mkdir(parents=True, exist_ok=True)
    shutil.copy2(devices[0], PREFIX / "lib" / "libanari_library_halogen.dylib")
    collect([PREFIX / "lib" / "libanari_library_halogen.dylib"],
            search=[devices[0].parent],
            licenses={"halogen": (src, 1), "filament": (src / "external" / "filament", 1)})


def part_viskores():
    """Viskores device, with the modules it needs only, as shared libraries, with the OpenMP
    backend (libomp of Homebrew). Built without logging : its logging library installs signal
    handlers when the device loads, which replace those of the host process."""
    anari_core()
    src = SRC / "viskores"
    clone("https://github.com/Viskores/viskores.git", src, opt("VISKORES_REF"))
    libomp = brew_prefix("libomp")
    cmake_build(src,
                f"-DCMAKE_PREFIX_PATH={PREFIX};{libomp}",
                "-DBUILD_SHARED_LIBS=ON",
                "-DViskores_BUILD_ALL_LIBRARIES=OFF",
                "-DViskores_ENABLE_RENDERING=ON",
                "-DViskores_ENABLE_ANARI=ON",
                "-DViskores_ENABLE_OPENMP=ON",
                "-DViskores_ENABLE_TESTING=OFF",
                "-DViskores_ENABLE_BENCHMARKS=OFF",
                "-DViskores_ENABLE_EXAMPLES=OFF",
                "-DViskores_ENABLE_TUTORIALS=OFF",
                "-DViskores_ENABLE_DOCUMENTATION=OFF",
                "-DViskores_ENABLE_PYTHON_BINDINGS=OFF",
                "-DViskores_ENABLE_MPI=OFF",
                "-DViskores_ENABLE_DEVELOPER_FLAGS=OFF",
                "-DViskores_ENABLE_LOGGING=OFF")
    MANIFEST.append(f"libomp {libomp.resolve().name} Homebrew")
    third = src / "viskores" / "thirdparty"
    collect([PREFIX / "lib" / "libanari_library_viskores*.dylib"],
            search=[libomp / "lib"],
            licenses={"viskores": (src, 1), "libomp": (libomp, 1),
                      "viskores-diy": (third / "diy" / "viskoresdiy", 1),
                      "viskores-lcl": (third / "lcl" / "viskoreslcl", 1),
                      "viskores-lodepng": (third / "lodepng" / "viskoreslodepng", 1)})


#----------------------------------------------------------------------------------------
# Collection : the seeds and every library they need, in dist/parts/<part>/lib
#----------------------------------------------------------------------------------------
def is_macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with open(path, "rb") as f:
        magic = f.read(4)
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def install_id(path):
    lines = run(["otool", "-D", path], capture=True, quiet=True).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def dependencies(path):
    """Install names of the libraries a library links to, its own id excluded."""
    own = install_id(path)
    names = []
    for line in run(["otool", "-L", path], capture=True, quiet=True).splitlines()[1:]:
        name = line.strip().split(" (compatibility")[0].strip()
        if name and name != own:
            names.append(name)
    return names


def rpaths(path):
    result = []
    lines = run(["otool", "-l", path], capture=True, quiet=True).splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for following in lines[i + 1:i + 4]:
                m = re.match(r"\s*path (.*) \(offset \d+\)", following)
                if m:
                    result.append(m.group(1))
                    break
    return result


def system(name):
    """Libraries of macOS, never shipped : the system, and Vulkan / MoltenVK, which SDL3
    loads at runtime when present."""
    if name.startswith(("/usr/lib/", "/System/")):
        return True
    return Path(name).name.startswith(("libvulkan", "libMoltenVK"))


def excluded(name):
    return system(name) or (PART != "sdk" and Path(name).name.startswith("libanari."))


def resolve(dep, origin, search):
    """File of a dependency, from the folder of the library referring to it (origin)."""
    base = Path(dep).name
    if dep.startswith("@loader_path/"):
        candidate = origin / dep[len("@loader_path/"):]
        if candidate.exists():
            return candidate
    elif dep.startswith("/") and Path(dep).exists():
        return Path(dep)
    for d in search:
        candidate = Path(d) / base
        if candidate.exists():
            return candidate
    return None


def collect(seeds, search=(), licenses=None):
    out = DIST / "parts" / PART
    lib = out / "lib"
    rmtree(out)
    lib.mkdir(parents=True)
    (out / "licenses").mkdir()
    origins = {}   # file name in lib -> folder it came from, for @loader_path and the rpaths

    # 1. seeds, with their names and symbolic links : some are loaded by name
    for pattern in seeds:
        matches = glob.glob(str(pattern))
        if not matches:
            sys.exit(f"Nothing matches {pattern}")
        for m in matches:
            m = Path(m)
            target = lib / m.name
            if target.exists() or target.is_symlink():
                continue
            if m.is_symlink():
                os.symlink(os.readlink(m), target)
                real = m.resolve()
                if not (lib / real.name).exists():
                    shutil.copy2(real, lib / real.name)
                    origins[real.name] = m.parent
            elif m.is_dir():
                shutil.copytree(m, target, symlinks=True)
            else:
                shutil.copy2(m, target)
                origins[m.name] = m.parent

    # 2. dependencies, repeated until nothing new is found, copied with the name they are
    #    referred to (the real file, not a link)
    changed = True
    while changed:
        changed = False
        for f in sorted(lib.iterdir()):
            if not is_macho(f):
                continue
            origin = origins.get(f.name, f.parent)
            dirs = [lib, PREFIX / "lib", *search]
            dirs += [Path(r.replace("@loader_path", str(origin))) for r in rpaths(f) if not r.startswith("@executable_path")]
            for dep in dependencies(f):
                base = Path(dep).name
                if excluded(dep) or (lib / base).exists():
                    continue
                found = resolve(dep, origin, dirs)
                if found is None:
                    print(f"  missing {dep} needed by {f.name}")
                    continue
                print(f"  add {base} from {found}")
                shutil.copy2(found.resolve(), lib / base)
                origins[base] = found.parent
                changed = True

    # 3. references as @rpath/<name>, search path @loader_path, ad hoc signature
    for f in sorted(lib.iterdir()):
        if not is_macho(f):
            continue
        os.chmod(f, 0o755)
        args = []
        own = install_id(f)
        if own:
            args += ["-id", f"@rpath/{Path(own).name}"]
        for dep in dependencies(f):
            if system(dep):
                continue
            wanted = f"@rpath/{Path(dep).name}"
            if dep != wanted:
                args += ["-change", dep, wanted]
        current = rpaths(f)
        for r in current:
            if r != "@loader_path":
                args += ["-delete_rpath", r]
        if "@loader_path" not in current:
            args += ["-add_rpath", "@loader_path"]
        if args:
            run(["install_name_tool", *args, f], quiet=True)
        run(["codesign", "--force", "--sign", "-", f], quiet=True)

    # 4. licenses and manifest
    for name, (directory, depth) in (licenses or {}).items():
        copy_licenses(Path(directory), depth, out / "licenses" / name)
    macos = run(["sw_vers", "-productVersion"], capture=True).strip()
    clang = run(["clang", "--version"], capture=True).splitlines()[0]
    lines = [f"Built : {now()}",
             f"Base  : macOS {macos}, {clang}, deployment target {opt('MACOS_DEPLOYMENT_TARGET', '14.0')}",
             "Components (name commit source) :"]
    (out / "MANIFEST.txt").write_text("\n".join(lines + MANIFEST) + "\n", encoding="utf-8")

    # 5. check
    print(f"Dependency check of part {PART} :")
    check(lib)


def copy_licenses(directory, depth, dest):
    if not directory.is_dir():
        return
    pattern = re.compile(r"^(licen[cs]e|copying|notice).*|.*third-party.*", re.IGNORECASE)
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


def check(lib):
    """Prints, for each device, the libraries not found in lib and whether macOS loads it like
    libanari does (dlopen with its full path)."""
    for device in sorted(lib.glob("libanari_library_*.dylib")):
        if device.is_symlink():
            continue
        missing = [d for d in dependencies(device)
                   if not excluded(d) and not (lib / Path(d).name).exists()]
        status = "ok" if not missing else "MISSING : " + " ".join(missing)
        load = subprocess.run([sys.executable, "-c", "import ctypes, sys; ctypes.CDLL(sys.argv[1])", str(device)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        error = load.stdout.strip().splitlines() or ["unknown error"]
        loaded = "loads" if load.returncode == 0 else "does not load : " + error[-1]
        print(f"  {device.name} {status}, {loaded}")


#----------------------------------------------------------------------------------------
# Bundle : the parts merged
#----------------------------------------------------------------------------------------
def assemble(name, parts):
    out = DIST / name
    rmtree(out)
    archive = DIST / (name + ".tar.gz")
    if archive.exists():
        archive.unlink()
    lib = out / "lib"
    (lib / "licenses").mkdir(parents=True)
    origin = {}
    for part in parts:
        src = DIST / "parts" / part
        if not (src / "lib").is_dir():
            sys.exit(f"Part {part} not found in {DIST / 'parts'}")
        print(f"Merging part {part}")
        for f in sorted((src / "lib").iterdir()):
            target = lib / f.name
            if f.name not in origin:
                if f.is_symlink():
                    os.symlink(os.readlink(f), target)
                elif f.is_dir():
                    shutil.copytree(f, target, symlinks=True)
                else:
                    shutil.copy2(f, target)
                origin[f.name] = part
            elif is_macho(f) and is_macho(target) and not filecmp.cmp(f, target, shallow=False):
                print(f"  {f.name} differs in parts {origin[f.name]} and {part} : the one of {origin[f.name]} is kept")
        shutil.copytree(src / "licenses", lib / "licenses", dirs_exist_ok=True)

    devices = sorted(re.sub(r"^libanari_library_(.*)\.dylib$", r"\1", f.name)
                     for f in lib.glob("libanari_library_*.dylib"))
    lines = ["ANARI native bundle"]
    if os.environ.get("BUNDLE_VERSION"):
        lines.append(f"Version : {os.environ['BUNDLE_VERSION']}")
    lines += [f"Assembled : {now()}", "", "Devices :"]
    lines += [f"  {d}" for d in devices]
    for part in parts:
        lines += ["", f"[{part}]", (DIST / "parts" / part / "MANIFEST.txt").read_text(encoding="utf-8").rstrip()]
    (out / "MANIFEST.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out / "README.txt").write_text(f"""libanari is lib/libanari.dylib. The devices are next to it (lib/libanari_library_<name>.dylib),
where anariLoadLibrary("<name>") finds them.

Libraries find each other through their @loader_path search path, DYLD_LIBRARY_PATH is not needed.
They have an ad hoc signature only : when the archive was downloaded with a web browser, remove
the quarantine attribute before use, otherwise macOS refuses to load them :
  xattr -dr com.apple.quarantine /path/to/{name}
Requires macOS {opt('MACOS_DEPLOYMENT_TARGET', '14.0')} or newer on Apple silicon (the viskores device may need the
macOS version of the build machine, through the libomp of Homebrew).
helide_gpu uses Metal through SDL_gpu.
See MANIFEST.txt for the component versions and lib/licenses/ for their licenses.
""", encoding="utf-8")

    print()
    print("Dependency check on this machine :")
    check(lib)
    with tarfile.open(archive, "w:gz") as t:
        t.add(out, arcname=name)
    print(f"Bundle : {out}")
    print(f"Archive : {archive} ({archive.stat().st_size // (1024 * 1024)} MB)")


#----------------------------------------------------------------------------------------
def main():
    global PART, WORK, SRC, PREFIX, OPT, DIST
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dist", type=Path, default=HERE / "dist", help="output folder (default: dist)")
    parser.add_argument("--work", type=Path, default=HERE / "work", help="sources and build folders (default: work)")
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
