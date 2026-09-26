# FlameLauncher-SDL3

Prebuilt **SDL3** and **LWJGL 3.4.3** natives for running Minecraft: Java Edition **26.3+** on
iOS (arm64) and Android (arm64-v8a) — plus the scripts that build them.

Minecraft 26.3 dropped GLFW entirely and moved windowing and input to SDL3, and it requires
LWJGL 3.4.3. Neither ships a build you can drop into a mobile launcher: SDL3's upstream iOS
backend only speaks EAGL (not the EGL/ANGLE stack every mobile GL translator sits on), and
LWJGL's build has no iOS target at all. These scripts produce both, with the patches that make
them work on a phone.

Everything here is built from upstream sources at a pinned tag. Nothing is vendored.

| | iOS arm64 | Android arm64-v8a |
|---|---|---|
| `libSDL3` | `.dylib` | `.so` |
| `liblwjgl`, `liblwjgl_opengl`, `liblwjgl_stb`, `liblwjgl_tinyfd` | `.dylib` | — |
| `liblwjgl`, `liblwjgl_opengl`, `liblwjgl_stb`, `liblwjgl_vma` | — | `.so` |

Grab them from [Releases](../../releases), or build them yourself (below).

## What is patched, and why

### SDL3 — `Scripts/build-sdl3.sh`

Built from `release-3.4.16`. The patches are applied to a fresh clone, so you can read them as
a list of problems rather than as a fork.

**iOS**

- **UIKit entry points are marshalled to the main thread.** SDL treats "the thread that called
  `SDL_Init`" as the main thread, but a launcher starts the JVM on a background thread — so the
  thread Minecraft calls "Render thread" is, to UIKit, a background thread. Window, display,
  text-input and Vulkan surface calls are wrapped so they run on the real main queue.
  GL calls are deliberately *not* wrapped: a GL context belongs to the thread that made it
  current, and swap happens every frame.
- **The GL backend runs on EGL instead of EAGL.** Mobile GL translators (MobileGlues, gl4es,
  Zink) expose EGL; SDL's uikit backend only knew EAGL. `SDL_GL_LoadLibrary` now hands the path
  Minecraft passes (the file LWJGL itself opened) straight to SDL's EGL loader, and pins it with
  `SDL_HINT_OPENGL_LIBRARY` at override priority, so SDL and LWJGL end up in the *same* library.
  26.3's GL backend compares `glGetError` addresses and refuses the backend otherwise.
- **A GL surface is created per window, when the window is first used.** 26.3 creates a hidden
  utility window, makes its context there, and only much later creates the real game window.
  One surface for the whole run means the game window stays empty.
- **`SDL_WINDOW_UTILITY` windows are created without a `UIWindow`** and get a pbuffer surface.
  The uikit backend allows one window per display, and 26.3's two hidden helper windows were
  taking that slot away from the game.
- **`UIKit_GL_RestoreCurrentContext` is skipped on EGL.** It casts `SDL_GLContext` to
  `EAGLContext`, and ARC then retains it — with an EGL handle that is a crash in `objc_retain`
  on the first frame after the event pump.
- **The render thread is parked while the app is in the background**, because iOS kills a
  process that touches the GPU there.

**Android**

- Desktop GL is folded to ES 3.2 without changing the version SDL reports.
- `SDL_WINDOW_UTILITY` windows go offscreen (pbuffer), same reasoning as iOS — keying on
  `HIDDEN` too would push the real window offscreen, because the game window is created hidden
  and shown later.
- A resize event is pushed at creation.

### LWJGL 3.4.3 — `Scripts/build-lwjgl-natives.sh`, `Scripts/build-lwjgl-natives-android.sh`

LWJGL's ant build has no iOS target, so the sources are compiled directly with clang using the
flags from LWJGL's own `config/macos/build.xml`. `libffi` is built from source and linked
statically into `liblwjgl` — 3.4.x rebuilt its callback layer on top of it
(`LibFFI.ffi_get_closure_size`), and a 3.3.3 native simply has no such symbol.

Java and natives must be the *same* version. A 3.4.3 jar on 3.4.1 natives dies in class init
with `UnsatisfiedLinkError: MemoryUtil.ngetPageSize()`.

The Android script is kept separate on purpose: the sources are shared but the toolchain,
platform macros (`LWJGL_LINUX` vs `LWJGL_MACOS`) and link steps are different enough that a
merged script would be harder to read than two.

## Building

macOS host (the scripts use `sysctl`, `/usr/libexec/java_home` and the NDK's `darwin-x86_64`
toolchain). Xcode is required for the iOS builds.

```sh
brew install cmake ninja automake libtool

./Scripts/build-sdl3.sh ios                    # → Runtime/SDL3/libSDL3.dylib
./Scripts/build-sdl3.sh android                # → Runtime/SDL3/android/arm64-v8a/libSDL3.so
./Scripts/build-sdl3.sh all

./Scripts/build-lwjgl-natives.sh               # → Runtime/Frameworks341/*.dylib
./Scripts/build-lwjgl-natives-android.sh       # → Runtime/lwjgl341/android/arm64-v8a/*.so
```

Both take an optional upstream tag: `./Scripts/build-sdl3.sh ios` reads `SDL_REF`
(default `release-3.4.16`), and the LWJGL scripts take the tag as `$1` (default `3.4.3`).

The Android builds need an NDK; set `ANDROID_NDK_HOME` if it is not under
`~/Library/Android/sdk/ndk`.

## Releases

Two independent tracks, each with its own workflow:

| Tag | Workflow | Assets |
|---|---|---|
| `sdl3-v*` | `.github/workflows/sdl3.yml` | `libSDL3-ios-arm64.dylib`, `libSDL3-android-arm64-v8a.so` |
| `lwjgl-v*` | `.github/workflows/lwjgl.yml` | `lwjgl-ios-arm64.zip`, `lwjgl-android-arm64-v8a.zip` |

Both also run on `workflow_dispatch`, where the upstream version is an input, so you can build
a different SDL or LWJGL release without touching the scripts.

## Licenses

The build scripts and patches are AGPL-3.0 (`LICENSE`) — they come from
[FlameLauncher](https://github.com/FlameLaunchers/FlameLauncher-Android). What they *produce*
is governed by each upstream project, and those texts are in `licenses/`:

| Output | Upstream | License |
|---|---|---|
| `libSDL3` | [SDL](https://github.com/libsdl-org/SDL) | Zlib |
| `liblwjgl*` | [LWJGL](https://github.com/LWJGL/lwjgl3) | BSD-3-Clause |
| (linked into `liblwjgl`) | [libffi](https://github.com/libffi/libffi) | MIT |
