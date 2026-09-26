#!/bin/bash
#
# LWJGL 네이티브를 Android(arm64-v8a)용으로 빌드한다. — 마인크래프트 26.3 전용 스택
#
# ── 왜 필요한가 ──────────────────────────────────────────────────────────────
# 안드로이드 앱이 들고 있는 liblwjgl.so 는 PojavLauncher 의 **3.3.3** 판이다.
# 26.3 은 org.lwjgl:*:3.4.3 을 요구하는데, jar 과 네이티브가 한 버전이라도
# 어긋나면 클래스 초기화에서 죽는다(iOS 에서 실측):
#     UnsatisfiedLinkError: 'int org.lwjgl.system.MemoryUtil.ngetPageSize()'
#
# 26.3 의 version.json 이 실제로 요구하는 네이티브는 이것뿐이다(natives-linux jar 실측):
#     liblwjgl.so  liblwjgl_stb.so  liblwjgl_vma.so  liblwjgl_opengl.so   ← 여기서 만든다
#     libSDL3.so                                            ← build-sdl3.sh android
#     libshaderc.so  libspirv-cross.so  libfreetype.so  libopenal.so  ← 앱에 이미 있다
#     libjemalloc.so                                        ← 없으면 LWJGL 이 기본 할당자로 간다
#     libvulkan.so                                          ← 안드로이드 시스템 것
#
# ⚠️ iOS 판(build-lwjgl-natives.sh)과 나란히 둔다. 소스는 같지만 플랫폼 매크로부터
#    (LWJGL_MACOS vs LWJGL_LINUX) 툴체인·링크 방식이 전부 달라서 한 파일로 합치면
#    양쪽 다 읽기 어려워진다.
#
# 사용:  Scripts/build-lwjgl-natives-android.sh [태그]      (기본 3.4.3)
set -euo pipefail

REF="${1:-3.4.3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Runtime/lwjgl341/android/arm64-v8a"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

API=26   # app/build.gradle.kts 의 minSdk 와 같다

NDK="${ANDROID_NDK_HOME:-}"
[ -n "$NDK" ] || NDK=$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | sort -V | tail -1 || true)
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "NDK 를 찾지 못했습니다 (ANDROID_NDK_HOME)"; exit 1; }
BIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
CC="$BIN/aarch64-linux-android$API-clang"
CXX="$BIN/aarch64-linux-android$API-clang++"
[ -x "$CC" ] || { echo "NDK 툴체인이 없습니다: $CC"; exit 1; }

# ⚠️ JDK 헤더는 **linux** 것을 쓴다(jni_md.h 가 플랫폼별이다). macOS 의 darwin/ 을
#    주면 jlong 이 long long 이 아닌 쪽으로 잡혀 시그니처가 조용히 어긋난다.
JH="${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home}"
[ -f "$JH/include/jni.h" ] || { echo "jni.h 를 가진 JDK 가 필요합니다 (JAVA_HOME)"; exit 1; }
mkdir -p "$WORK/jni"
cp "$JH/include/jni.h" "$WORK/jni/"
# darwin/macos 판 JDK 에는 include/linux 가 없다. jni_md.h 는 내용이 이게 전부다.
cat > "$WORK/jni/jni_md.h" <<'HDR'
#pragma once
#define JNIEXPORT __attribute__((visibility("default")))
#define JNIIMPORT
#define JNICALL
typedef int jint;
typedef long long jlong;
typedef signed char jbyte;
HDR

echo "▸ NDK: ${NDK##*/}   JDK: ${JH##*/}   출력: ${OUT#"$ROOT/"}"

# ── libffi ───────────────────────────────────────────────────────────────────
# LWJGL 소스에는 헤더만 있고 .a 는 빌드 서버가 만든다. 직접 만든다.
# (Upcalls/Callback 이 여기에 걸려 있어서 없으면 콜백 만드는 순간 죽는다)
echo "▸ libffi (android arm64)"
command -v aclocal >/dev/null || { echo "automake 가 필요합니다: brew install automake"; exit 1; }
git clone --depth 1 https://github.com/libffi/libffi.git "$WORK/libffi" >/dev/null 2>&1
( cd "$WORK/libffi" && ACLOCAL_PATH=/opt/homebrew/share/aclocal ./autogen.sh ) >/dev/null 2>&1
mkdir -p "$WORK/libffi/b"
( cd "$WORK/libffi/b" && ../configure --host=aarch64-linux-android \
    --disable-shared --enable-static --disable-docs \
    CC="$CC" CCAS="$CC" CFLAGS="-O2 -fPIC" ) >/dev/null 2>&1
( cd "$WORK/libffi/b" && make -j"$(sysctl -n hw.ncpu)" ) >/dev/null 2>&1
FFI_A="$WORK/libffi/b/.libs/libffi.a"
[ -f "$FFI_A" ] || { echo "libffi 빌드 실패"; exit 1; }

# ── LWJGL ────────────────────────────────────────────────────────────────────
echo "▸ LWJGL ($REF) 받는 중…"
git clone --depth 1 --branch "$REF" https://github.com/LWJGL/lwjgl3.git "$WORK/lwjgl3" >/dev/null 2>&1
M="$WORK/lwjgl3/modules/lwjgl"

# ⚠️ 아키텍처 매크로는 **소문자**다 (`-DLWJGL_${build.arch}`). 대문자로 주면 libffi
#    헤더의 분기가 어긋나 ffi_closure 레이아웃이 달라지고, 콜백 user_data 가 0 이 된다.
#    (iOS 판에서 실측한 함정 — 같은 헤더를 쓰므로 여기서도 같다)
CFLAGS_COMMON="-O2 -fPIC -DNDEBUG -DLWJGL_LINUX -DLWJGL_arm64 -Wno-everything
  -I$WORK/jni
  -I$M/core/src/main/c -I$M/core/src/main/c/libffi -I$M/core/src/main/c/libffi/aarch64
  -I$M/core/src/main/c/linux"

build_lib() {           # build_lib <이름> <출력> <추가 include…> -- <소스…>
  local name="$1" out="$2" cc="${BUILD_CC:-$CC}"; shift 2
  local incs=() srcs=() seen_sep=0
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen_sep=1; continue; fi
    if [ $seen_sep -eq 0 ]; then incs+=("$a"); else srcs+=("$a"); fi
  done
  local d="$WORK/o/$name"; mkdir -p "$d"
  ( cd "$d" && $cc -c $CFLAGS_COMMON ${incs[@]+"${incs[@]}"} "${srcs[@]}" )
  ( cd "$d" && $cc -shared -o "$out" ./*.o -llog ${EXTRA_LINK[@]+"${EXTRA_LINK[@]}"} )
  "$BIN/llvm-strip" --strip-unneeded "$out"
  printf '    %-24s %s\n' "$(basename "$out")" "$(du -h "$out" | cut -f1)"
}

mkdir -p "$OUT"
echo "▸ 빌드"

# ⚠️ liburing 바인딩은 뺀다. 비오닉에는 liburing 이 없고(LWJGL 이 헤더만 번들한다)
#    마인크래프트는 이 클래스를 한 번도 건드리지 않는다.
CORE_SRCS=$(ls "$M"/core/src/main/c/*.c "$M"/core/src/generated/c/*.c \
               "$M"/core/src/generated/c/linux/*.c | grep -v liburing)

EXTRA_LINK=("$FFI_A")
build_lib core "$OUT/liblwjgl.so" -- $CORE_SRCS

EXTRA_LINK=()
# stb 는 헤더 전용이다. 생성 소스가 구현을 #include 하므로 include 경로만 준다.
build_lib stb "$OUT/liblwjgl_stb.so" -I"$M/stb/src/main/c" -- "$M"/stb/src/generated/c/*.c

# ⚠️ WGL/GLX 는 윈도우·X11 전용이라 뺀다(헤더부터 없다). 안드로이드에서는 GL 함수 포인터를
#    MobileGlues 같은 번역 계층에서 받아 온다 — 26.3 의 GL 백엔드가 그 경로를 쓴다.
OPENGL_SRCS=$(ls "$M"/opengl/src/generated/c/*.c | grep -vE "_(WGL|GLX)[A-Za-z0-9_]*\.c$|_opengl_(WGL|GLX)\.c$")
build_lib opengl "$OUT/liblwjgl_opengl.so" -I"$M/opengl/src/main/c" -- $OPENGL_SRCS

# VMA 는 C++ 이고 Vulkan 헤더를 쓴다(NDK 가 갖고 있다).
BUILD_CC="$CXX" build_lib vma "$OUT/liblwjgl_vma.so" \
  -I"$M/vma/src/main/c" -I"$M/vulkan/src/main/c" -- "$M"/vma/src/generated/c/*.cpp

echo
echo "완료 — LWJGL $REF 안드로이드 네이티브 → ${OUT#"$ROOT/"}"
