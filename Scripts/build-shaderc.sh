#!/bin/bash
#
# shaderc (iOS arm64 · Android arm64-v8a) — 마인크래프트 26.3 의 렌더 엔진이 런타임에 쓴다.
#
# 사용:  Scripts/build-shaderc.sh [ios|android]     (기본 ios)
#
# ⚠️ 왜 필요한가
#    26.3 의 새 렌더 엔진 `com.mojang.renderpearl` 은 GLSL 을 **실행 중에** SPIR-V 로
#    컴파일해서 Vulkan 파이프라인을 만든다. 그 컴파일러가 shaderc 다:
#      GlslCompiler.createBaseShaderOptions → Shaderc.shaderc_compile_options_initialize
#
# ⚠️ 왜 새로 빌드하는가
#    저장소에 있던 libshaderc.dylib 은 어디선가 가져온 구버전이라 LWJGL 3.4.3 이
#    요구하는 진입점 45개 중 **하나가 없었다**:
#      NullPointerException: A required function is missing:
#        shaderc_compile_options_set_max_id_bound
#    LWJGL 은 진입점 하나만 없어도 Functions 클래스 초기화 단계에서 통째로 실패한다.
#
# ⚠️ 의존이 크다. shaderc 는 glslang + SPIRV-Tools + SPIRV-Headers 를 함께 빌드한다.
#    업스트림이 주는 git-sync-deps 로 정확한 조합을 받아야 한다 — 각자 최신을 받으면
#    서로 안 맞는다.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="https://github.com/google/shaderc.git"
# ⚠️ 태그를 고정한다. main 을 쓰면 빌드마다 결과가 달라지고, 어느 날 조용히
#    진입점이 사라져도 알 수 없다.
REF="${SHADERC_REF:-v2026.4}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ shaderc ($REF) 받는 중…"
git clone --depth 1 --branch "$REF" "$REPO" "$WORK/src" >/dev/null 2>&1 || {
  echo "  태그 $REF 를 못 받았습니다 — 최신 태그를 확인하세요"; exit 1; }

echo "▸ 의존 동기화 (glslang · SPIRV-Tools · SPIRV-Headers)"
python3 "$WORK/src/utils/git-sync-deps" >/dev/null 2>&1 || {
  echo "  git-sync-deps 실패"; exit 1; }

TARGET="${1:-ios}"

if [ "$TARGET" = "android" ]; then
  # ⚠️ 안드로이드도 같은 이유로 새로 빌드한다. 앱에 있던 libshaderc.so 는
  #    PojavLauncher 판이라 shaderc_compile_options_set_max_id_bound 가 없다(기기 실측).
  NDK="${ANDROID_NDK_HOME:-}"
  [ -n "$NDK" ] || NDK=$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$NDK" ] && [ -d "$NDK" ] || { echo "NDK 를 찾지 못했습니다 (ANDROID_NDK_HOME)"; exit 1; }
  BIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"

  echo "▸ 빌드 (Android arm64-v8a, NDK ${NDK##*/})"
  cmake -S "$WORK/src" -B "$WORK/build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
    -DCMAKE_BUILD_TYPE=Release \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DSHADERC_ENABLE_WERROR_COMPILE=OFF \
    -DBUILD_SHARED_LIBS=OFF -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_SKIP_TESTS=ON \
    -DENABLE_GLSLANG_BINARIES=OFF \
    > "$WORK/cfg.log" 2>&1 || {
      echo "  ✗ cmake 구성 실패:"; tail -20 "$WORK/cfg.log" | sed 's/^/    /'; exit 1; }

  cmake --build "$WORK/build" --target shaderc_shared -j"$(sysctl -n hw.ncpu)" \
    > "$WORK/build.log" 2>&1 || {
      echo "  ✗ 빌드 실패:"; grep -E "error:" "$WORK/build.log" | head -12 | sed 's/^/    /'; exit 1; }

  lib=$(find "$WORK/build" -name "libshaderc_shared.so" -type f | head -1)
  [ -n "$lib" ] || { echo "  ✗ libshaderc_shared.so 가 없습니다"; exit 1; }
  case "$(file "$lib")" in *aarch64*) ;; *) echo "  ✗ aarch64 가 아닙니다"; exit 1 ;; esac

  # iOS 쪽과 같은 이유로 진입점을 여기서 확인한다 — 기기에서 알게 되면 늦다.
  syms=$("$BIN/llvm-nm" -D --defined-only "$lib")
  for sym in shaderc_compile_options_initialize shaderc_compile_options_set_max_id_bound \
             shaderc_compile_into_spv shaderc_compiler_initialize shaderc_result_get_bytes; do
    case "$syms" in *" T $sym"*) ;; *) echo "  ✗ $sym 없음"; exit 1 ;; esac
  done

  out="$ROOT/Runtime/shaderc/android/arm64-v8a"
  mkdir -p "$out"
  cp "$lib" "$out/libshaderc.so"
  "$BIN/llvm-strip" --strip-unneeded "$out/libshaderc.so"
  echo "  완료: ${out#"$ROOT/"}/libshaderc.so ($(du -h "$out/libshaderc.so" | cut -f1))"
  exit 0
fi

echo "▸ 빌드 (iOS arm64)"
# ⚠️ 테스트·예제를 끈다. 켜면 호스트용 실행 파일을 만들려 해서 iOS 크로스 빌드가 깨진다.
cmake -S "$WORK/src" -B "$WORK/build" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release \
  -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
  -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DSHADERC_ENABLE_WERROR_COMPILE=OFF \
  -DBUILD_SHARED_LIBS=OFF -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_SKIP_TESTS=ON \
  -DENABLE_GLSLANG_BINARIES=OFF \
  > "$WORK/cfg.log" 2>&1 || {
    echo "  ✗ cmake 구성 실패:"; tail -20 "$WORK/cfg.log" | sed 's/^/    /'; exit 1; }

cmake --build "$WORK/build" --target shaderc_shared -j"$(sysctl -n hw.ncpu)" \
  > "$WORK/build.log" 2>&1 || {
    echo "  ✗ 빌드 실패:"; grep -E "error:" "$WORK/build.log" | head -12 | sed 's/^/    /'; exit 1; }

lib=$(find "$WORK/build" -name "libshaderc_shared*.dylib" -type f | head -1)
[ -n "$lib" ] || { echo "  ✗ libshaderc_shared dylib 이 없습니다"; exit 1; }

# cmake 는 타깃을 틀려도 조용히 성공한다. 앱에 넣는 순간에야 알게 되므로 여기서 자른다.
case "$(lipo -info "$lib")" in *arm64*) ;; *) echo "  ✗ arm64 가 아닙니다"; exit 1 ;; esac
plats=$(otool -l "$lib" | sed -n 's/^ *platform //p' | sort -u | tr '\n' ' ')
case "$plats" in "2 ") ;; *) echo "  ✗ iOS 전용이 아닙니다 (platform=$plats)"; exit 1 ;; esac

# ⚠️ LWJGL 이 요구하는 진입점이 **하나라도** 빠지면 Functions 클래스 초기화가 통째로
#    실패한다. 그래서 빌드가 끝난 자리에서 확인한다 — 기기에서 알게 되면 늦다.
#    (`nm | grep -q` 는 쓰지 않는다. grep 이 먼저 끝나며 nm 을 SIGPIPE 로 죽이고
#     pipefail 이 그걸 실패로 본다 — build-sdl3.sh 에서 겪었다)
syms=$(nm -gU "$lib")
for sym in _shaderc_compile_options_initialize _shaderc_compile_options_set_max_id_bound \
           _shaderc_compile_into_spv _shaderc_compiler_initialize _shaderc_result_get_bytes; do
  case "$syms" in *" T $sym"*) ;; *) echo "  ✗ $sym 없음"; exit 1 ;; esac
done

install_name_tool -id "@rpath/libshaderc.dylib" "$lib" 2>/dev/null || true
mkdir -p "$ROOT/Runtime/Frameworks"
cp "$lib" "$ROOT/Runtime/Frameworks/libshaderc.dylib"
echo "  완료: Runtime/Frameworks/libshaderc.dylib ($(du -h "$lib" | cut -f1))"
