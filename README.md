# ANARI SDK bundles

Prebuilt [ANARI](https://www.khronos.org/anari) native libraries: libanari and its devices, with every library they need, in one folder per operating system, so applications do not have to compile or install ANARI themselves.

The bundles are published as [releases](../../releases), one release per operating system and version:

| Operating system | Workflow | Tag | Archive | Build |
|---|---|---|---|---|
| Linux x86_64 | `Release Linux` | `linux/<version>` | `anari-linux-x86_64-<version>.tar.gz` | [linux/](linux/README.md), container images |
| Windows x86_64 | `Release Windows` | `windows/<version>` | `anari-windows-x86_64-<version>.zip` | [windows/](windows/README.md), Visual Studio 2022 |
| macOS arm64 (Apple silicon) | `Release macOS` | `macos/<version>` | `anari-macos-arm64-<version>.tar.gz` | [macos/](macos/README.md), Apple Clang |

The devices differ between operating systems: the CUDA devices need an NVIDIA GPU, which macOS does not support, and some devices have no upstream build on Windows or macOS yet. See the README of each folder.

In each bundle, the license files of the components (devices and the libraries they need) are in `licenses/`, next to the libraries (`lib/licenses/`, or `bin\licenses\` on Windows), one folder per component.

## Making a release

In the Actions tab, select the workflow of the operating system, then `Run workflow`:

- `version`: the version of the release, for example `1.0.0`. The tag is `<os>/<version>`, and the version is part of the archive name. The workflow stops if the tag already exists.
- `build-args`: optional build options, space separated `NAME=value`, for example `ANARI_SDK_REF=v0.15.0`. The workflows set `JOBS=3` unless given, and the Linux one also `CYCLES_OPTIX=OFF` (Cycles CPU only). See the Options section of [linux](linux/README.md#options), [windows](windows/README.md#options) and [macos](macos/README.md#options).

The workflow builds the bundle, then creates the tag on the commit it runs on and a release holding the archive, with the component versions in the release notes. When a job fails, `Re-run failed jobs` resumes the run: the release is created once every job succeeded.

## releases.log

Each release adds one line to [releases.log](releases.log), committed on the default branch:

```
<os>;<version>;<download url>
linux;1.0.0;https://github.com/<owner>/<repository>/releases/download/linux/1.0.0/anari-linux-x86_64-1.0.0.tar.gz
```

The workflow pushes this commit with the workflow token: if the default branch is protected, allow GitHub Actions to push to it.

To build a bundle on your own machine, see the README of its folder.
