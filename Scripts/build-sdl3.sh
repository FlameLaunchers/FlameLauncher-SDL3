#!/bin/bash
#
# 마인크래프트 26.3+ 용 SDL3 빌드 (iOS arm64 · Android arm64-v8a).
#
# ⚠️ 왜 필요한가
#    26.3 부터 마인크래프트는 GLFW 를 **완전히 버리고** SDL3 로 갔다. 26.3 의
#    version.json 에 glfw 라이브러리가 하나도 없고 org.lwjgl:lwjgl-sdl:3.4.3 이 들어온다.
#    클라이언트 jar 을 뜯어 세어 보면 SDL 진입점 84개를 27개 클래스가 쓴다.
#
# ⚠️ 좋은 소식: **JNI 글루를 만들 필요가 없다.**
#    lwjgl-sdl 의 natives jar 을 열어 보면 들어 있는 건 libSDL3.so 하나뿐이고,
#    바인딩은 전부 `JNI.invokeP*` + 함수 포인터다. GLFW 때처럼 자바 쪽을 재구현하거나
#    liblwjgl_glfw 를 따로 만들 이유가 없다 — SDL3 본체만 있으면 된다.
#
# ⚠️ 그리고 GLFW 와 달리 SDL3 는 **모바일 백엔드를 원래 갖고 있다**
#    (src/video/uikit · src/video/android). 우리가 창·입력을 통째로 재구현했던
#    이유가 GLFW 에 그게 없어서였는데, 여기서는 상류가 이미 지원한다.
#
# ⚠️ 다만 붙이는 일은 플랫폼마다 다르다 — 이 스크립트는 **본체를 만들 뿐**이다:
#      iOS     SDL_PROP_WINDOW_CREATE_* 에 UIKit 뷰 포인터가 없어서(Cocoa 만 있다)
#              우리 뷰를 넘길 공식 경로가 없다. GL 도 EAGL 경로뿐이라
#              ANGLE/EGL 위에 얹은 MobileGlues 와 바로 맞물리지 않는다.
#              → SDL 이 창을 소유하게 하고 GL 만 우리가 대는
#                (SDL_PROP_WINDOW_CREATE_EXTERNAL_GRAPHICS_CONTEXT_BOOLEAN) 방향이 유력하다.
#      Android EGL 이 네이티브라 GL 경로가 우리 렌더러들과 같은 토대를 쓴다.
#              SDL 의 Activity/Surface 와 우리 것을 맞추는 일만 남는다.
#
# 사용법:  ./Scripts/build-sdl3.sh [ios|android|all]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-all}"

REPO="https://github.com/libsdl-org/SDL.git"
# ⚠️ main 을 쓰지 않는다. lwjgl-sdl 3.4.3 이 기대하는 ABI 에 맞춰 안정 태그로 고정한다.
#    (SDL3 는 ABI 안정성을 약속하지만, 빌드가 조용히 달라지는 것을 막으려면 고정해야 한다)
REF="${SDL_REF:-release-3.4.16}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ SDL3 ($REF) 받는 중…"
git clone --depth 1 --branch "$REF" "$REPO" "$WORK/src" >/dev/null 2>&1
ver=$(grep -E "SDL_(MAJOR|MINOR|MICRO)_VERSION +[0-9]" "$WORK/src/include/SDL3/SDL_version.h" \
        | grep -oE "[0-9]+$" | paste -sd. -)
echo "  버전 $ver"

# 공통 옵션. 테스트·예제는 필요 없고, 우리는 정적/동적을 플랫폼마다 다르게 쓴다.
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF)

# ⚠️ iOS: UIKit 을 건드리는 진입점을 **메인 스레드로 넘긴다**.
#
#    SDL 의 uikit 백엔드는 UIWindow·UIScreen·CAEAGLLayer 를 만지므로 메인 스레드에서만
#    안전하다. 그런데 SDL 은 "SDL_Init 을 부른 스레드"를 메인으로 간주할 뿐이고
#    (src/SDL.c 의 SDL_MainThreadID), 진짜 UIKit 메인 스레드인지는 보지 않는다.
#
#    우리 구조에서는 그게 어긋난다. `-XstartOnFirstThread` 의 "첫 스레드"는 JLI 를 부른
#    스레드인데 런처는 JVM 을 백그라운드에서 띄운다 — 그래서 마인크래프트가
#    "Render thread" 라 부르는 JVM 메인이 UIKit 관점에서는 백그라운드다. 실측:
#      [FlameSDL] SDL_Init 호출 — 현재 스레드: 백그라운드   → 로그 한 줄 없이 사망
#      (메인 큐로 넘기면)     ✅ SDL_Init(VIDEO) 성공 — 드라이버 'uikit'
#
#    래퍼 dylib 도 검토했지만 나머지 심볼을 전부 다시 내보내야 해서(트램폴린 생성)
#    원본을 고치는 쪽이 훨씬 작다. MobileGlues 에 쓰는 방식과 같다.
#
# ⚠️ 두 파일 다 `.c` 라 ObjC 블록을 못 쓴다. GCD 의 C API(dispatch_sync_f)를 쓴다.
# ⚠️ 이미 메인이면 dispatch_sync 는 교착이다. pthread_main_np() 로 먼저 가른다.
patch_ios_mainthread() {
  local src="$1"
  python3 - "$src" <<'SDLPATCH'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])

PRELUDE = """
/* ── FlameLauncher: UIKit 진입점을 메인 스레드로 ──────────────────────────
   자세한 사정은 Scripts/build-sdl3.sh 의 patch_ios_mainthread 주석 참고. */
#ifdef SDL_PLATFORM_IOS
#include <dispatch/dispatch.h>
#include <pthread.h>
#endif
"""

def split_arg(a):
    """'const SDL_DisplayMode *mode' -> ('const SDL_DisplayMode *', 'mode')"""
    a = a.strip()
    m = re.match(r"^(.*?)([A-Za-z_][A-Za-z_0-9]*)$", a)
    return m.group(1).strip(), m.group(2)

def wrap(path, decl):
    """decl 예: 'bool SDL_SetWindowTitle(SDL_Window *window, const char *title)'"""
    p = root / path
    s = p.read_text()
    assert decl in s, f"{path}: 앵커를 못 찾았습니다 — {decl}"

    head, argstr = decl.split("(", 1)
    argstr = argstr.rstrip(")")
    name = re.match(r"^.*?([A-Za-z_][A-Za-z_0-9]*)$", head.strip()).group(1)
    ret = head.strip()[: -len(name)].strip()
    args = [] if argstr.strip() in ("", "void") else [split_arg(a) for a in argstr.split(",")]

    # ⚠️ 함수 이름만 바꾼다. decl 전체에 replace 를 걸면 반환 타입이 먼저 걸린다
    #    (SDL_Window *SDL_CreateWindow… → flame_real_SDL_Window *…).
    s = s.replace(decl, "static " + decl.replace(name + "(", "flame_real_" + name + "(", 1), 1)

    fields = "".join(f"    {t} {n};\n" for t, n in args)
    voidret = ret == "void"
    if not voidret:
        fields += f"    {ret} result;\n"
    call = f"flame_real_{name}(" + ", ".join(f"c->{n}" for _, n in args) + ")"
    direct = f"flame_real_{name}(" + ", ".join(n for _, n in args) + ")"
    assign = "" if voidret else "c->result = "
    setup = "".join(f"    c.{n} = {n};\n" for _, n in args)

    s += f"""
#ifdef SDL_PLATFORM_IOS
struct flame_ctx_{name} {{
{fields}}};
static void flame_thunk_{name}(void *p) {{
    struct flame_ctx_{name} *c = (struct flame_ctx_{name} *)p;
    {assign}{call};
}}
{decl} {{
    if (pthread_main_np()) {{ {'' if voidret else 'return '}{direct}; {'return;' if voidret else ''} }}
    struct flame_ctx_{name} c;
{setup}    dispatch_sync_f(dispatch_get_main_queue(), &c, flame_thunk_{name});
    {'' if voidret else 'return c.result;'}
}}
#endif
"""
    p.write_text(s)
    print(f"  {path}: {name}")

for path in ("src/SDL.c", "src/video/SDL_video.c", "src/events/SDL_mouse.c", "src/misc/SDL_url.c"):
    q = root / path
    q.write_text(q.read_text() + PRELUDE)

# ⚠️ Vulkan 진입점은 선언이 **여러 줄**이라 아래 파서가 못 잡는다. 한 줄로 편다.
#    (26.3 은 Vulkan 으로 그린다 — GL 이 아니다. 실측 스택:
#       UIKit_Vulkan_CreateSurface → UIKit_Metal_CreateView → -[SDL_uikitview setSDLWindow:]
#     이게 UIKit 을 백그라운드에서 만져 앱이 통째로 죽던 원인이다.)
vid = root / "src/video/SDL_video.c"
t = vid.read_text()
for multi, single in [
    ("""bool SDL_Vulkan_CreateSurface(SDL_Window *window,
                                  VkInstance instance,
                                  const struct VkAllocationCallbacks *allocator,
                                  VkSurfaceKHR *surface)""",
     "bool SDL_Vulkan_CreateSurface(SDL_Window *window, VkInstance instance, const struct VkAllocationCallbacks *allocator, VkSurfaceKHR *surface)"),
    ("""void SDL_Vulkan_DestroySurface(VkInstance instance,
                               VkSurfaceKHR surface,
                               const struct VkAllocationCallbacks *allocator)""",
     "void SDL_Vulkan_DestroySurface(VkInstance instance, VkSurfaceKHR surface, const struct VkAllocationCallbacks *allocator)"),
]:
    assert multi in t, "Vulkan 선언을 못 찾았습니다 (업스트림이 바뀜)"
    t = t.replace(multi, single, 1)
vid.write_text(t)

# ⚠️ GL 함수는 감싸지 않는다. SDL_GL_SwapWindow 는 매 프레임 불리고, GL 컨텍스트는
#    스레드에 묶이므로 메인으로 넘기면 정작 그리는 스레드에서 current 가 아니게 된다.
#    (GL 은 우리 ANGLE 로 대체할 예정이라 어차피 이 경로를 안 탄다)
wrap("src/SDL.c", "bool SDL_InitSubSystem(SDL_InitFlags flags)")
# ⚠️ **종료도 UIKit 이다.** 26.3 은 "게임 종료" 때 렌더 스레드에서 SDL_Quit 을 부르고,
#    SDL 은 정리하면서 화면 자동 잠금을 되돌린다. 메인이 아니면 FrontBoard 가 트랩을 건다:
#      SDL_Quit → SDL_VideoQuit → UIKit_SuspendScreenSaver
#      → -[UIApplication _setIdleTimerDisabled:forReason:] → assertBarrierOnQueue (EXC_BREAKPOINT)
wrap("src/SDL.c", "void SDL_Quit(void)")
# 채팅 링크 등 — -[UIApplication openURL:…] 을 그대로 부른다(misc/ios/SDL_sysurl.m).
wrap("src/misc/SDL_url.c", "bool SDL_OpenURL(const char *url)")

for decl in [
    "SDL_Window *SDL_CreateWindowWithProperties(SDL_PropertiesID props)",
    "void SDL_DestroyWindow(SDL_Window *window)",
    "bool SDL_SetWindowIcon(SDL_Window *window, SDL_Surface *icon)",
    "bool SDL_SetWindowBordered(SDL_Window *window, bool bordered)",
    "bool SDL_SetWindowSize(SDL_Window *window, int w, int h)",
    "bool SDL_SetWindowPosition(SDL_Window *window, int x, int y)",
    "bool SDL_SetWindowMinimumSize(SDL_Window *window, int min_w, int min_h)",
    "bool SDL_SetWindowMaximumSize(SDL_Window *window, int max_w, int max_h)",
    "bool SDL_SetWindowFullscreenMode(SDL_Window *window, const SDL_DisplayMode *mode)",
    "bool SDL_RaiseWindow(SDL_Window *window)",
    "bool SDL_ShowWindow(SDL_Window *window)",
    "bool SDL_HideWindow(SDL_Window *window)",
    "bool SDL_SetWindowFullscreen(SDL_Window *window, bool fullscreen)",
    "bool SDL_SyncWindow(SDL_Window *window)",
    "bool SDL_SetWindowTitle(SDL_Window *window, const char *title)",
    "bool SDL_SetWindowMouseGrab(SDL_Window *window, bool grabbed)",
    "bool SDL_SetWindowResizable(SDL_Window *window, bool resizable)",
    "bool SDL_SetWindowAlwaysOnTop(SDL_Window *window, bool on_top)",
    "bool SDL_MaximizeWindow(SDL_Window *window)",
    "bool SDL_MinimizeWindow(SDL_Window *window)",
    "bool SDL_RestoreWindow(SDL_Window *window)",
    # ⚠️ GL **컨텍스트 생성**만 감싼다. CAEAGLLayer 를 만들며 UIKit 을 건드리기
    #    때문이다.
    #    SwapWindow/MakeCurrent 는 감싸지 않는다 — 매 프레임 불리고 컨텍스트가
    #    스레드에 묶이므로 메인으로 넘기면 그리는 스레드에서 current 가 아니게 된다.
    #
    # ⚠️ SDL_GL_CreateContext 도 **감싸지 않는다.** EAGL 시절엔 메인에서 만들어도 됐지만,
    #    지금은 우리 패치가 EGL(ANGLE) 컨텍스트를 만든다. SDL_EGL_CreateContext 는 만든 그
    #    자리에서 current 로 만들어 버리므로, 메인에서 만들면 컨텍스트가 메인에 묶이고
    #    렌더 스레드가 가져가려 할 때 EGL_BAD_ACCESS 로 거절당한다(실측: ctx=0x2 가 메인에
    #    묶인 채 렌더 스레드에서 MakeCurrent 실패). UIKit 이 필요한 뷰 생성만 메인으로 넘긴다.
    "bool SDL_GL_DestroyContext(SDL_GLContext context)",
    # ⚠️ **getter 도 감싸야 한다.** setter 만 감쌌더니 그대로 터졌다 —
    #    이것들은 UIWindow·UIScreen 을 조회하므로 UIKit 호출이다.
    "bool SDL_GetWindowPosition(SDL_Window *window, int *x, int *y)",
    "bool SDL_GetWindowSize(SDL_Window *window, int *w, int *h)",
    "bool SDL_GetWindowSizeInPixels(SDL_Window *window, int *w, int *h)",
    "SDL_WindowFlags SDL_GetWindowFlags(SDL_Window *window)",
    "SDL_DisplayID SDL_GetDisplayForWindow(SDL_Window *window)",
    "SDL_DisplayID SDL_GetPrimaryDisplay(void)",
    "bool SDL_GetDisplayBounds(SDL_DisplayID displayID, SDL_Rect *rect)",
    "bool SDL_GetDisplayUsableBounds(SDL_DisplayID displayID, SDL_Rect *rect)",
    "const SDL_DisplayMode *SDL_GetCurrentDisplayMode(SDL_DisplayID displayID)",
    "const SDL_DisplayMode *SDL_GetDesktopDisplayMode(SDL_DisplayID displayID)",
    # ⚠️ **이게 실제 크래시 지점이었다.** 26.3 은 Vulkan 으로 그리고, 이 함수가
    #    Metal 뷰를 만들며 UIKit 을 탄다.
    "bool SDL_Vulkan_CreateSurface(SDL_Window *window, VkInstance instance, const struct VkAllocationCallbacks *allocator, VkSurfaceKHR *surface)",
    "void SDL_Vulkan_DestroySurface(VkInstance instance, VkSurfaceKHR surface, const struct VkAllocationCallbacks *allocator)",
    "bool SDL_Vulkan_LoadLibrary(const char *path)",
    "void SDL_Vulkan_UnloadLibrary(void)",
    # ⚠️ **텍스트 입력도 UIKit 이다.** 26.3 은 입력칸(EditBox)에 포커스가 가면 렌더 스레드에서
    #    TextInputManager.startTextInput → SDL_StartTextInput → -[UITextField becomeFirstResponder]
    #    로 내려간다. 월드 이름·채팅·서버 주소 칸이 전부 이 경로다.
    #    SDL_StartTextInput 은 WithProperties 를 부르기만 하므로 그쪽을 감싼다.
    "bool SDL_StartTextInputWithProperties(SDL_Window *window, SDL_PropertiesID props)",
    "bool SDL_StopTextInput(SDL_Window *window)",
    "bool SDL_SetTextInputArea(SDL_Window *window, const SDL_Rect *rect, int cursor)",
]:
    wrap("src/video/SDL_video.c", decl)

# 마우스 커서 조작도 UIKit 을 탄다(SDL_mouse.c).
for decl in [
    "void SDL_WarpMouseInWindow(SDL_Window *window, float x, float y)",
    "bool SDL_ShowCursor(void)",
    "bool SDL_HideCursor(void)",
]:
    wrap("src/events/SDL_mouse.c", decl)

def patch(path, anchor, replacement):
    p = root / path
    s = p.read_text()
    assert anchor in s, f"{path}: 앵커를 못 찾았습니다 — {anchor.strip()[:60]}"
    p.write_text(s.replace(anchor, replacement, 1))
    print(f"  {path}: {anchor.strip().splitlines()[0][:50]}")

# ⚠️ **창 크기를 이벤트 없이 바꾼다.** SetupWindowData 가 실제 뷰 크기(852x393 pt)를
#    window->w/h 에 바로 넣고, 뒤따르는 RESIZED 는 같은 값이라 SDL_SendWindowEvent 가 걸러 버린다.
#    26.3 의 Window 는 화면 크기를 --width/--height(기본 854x480)로 시작해 **RESIZED 로만**
#    고친다(Window.<init> · onResize). 그래서 게임은 끝까지 854x480 이라 믿고
#    마우스 y 를 `y × GUI높이 / 480` 으로 계산했다 — 화면 아래로 갈수록 터치가 위로 밀렸다.
#    창을 다 만든 뒤 실제 크기를 한 번 직접 알린다.
patch("src/video/uikit/SDL_uikitwindow.m",
      "    SDL_SetNumberProperty(props, SDL_PROP_WINDOW_UIKIT_METAL_VIEW_TAG_NUMBER, SDL_METALVIEW_TAG);\n",
      """    SDL_SetNumberProperty(props, SDL_PROP_WINDOW_UIKIT_METAL_VIEW_TAG_NUMBER, SDL_METALVIEW_TAG);

    /* FlameLauncher: 위에서 이벤트 없이 바꾼 크기를 앱에 알린다(Scripts/build-sdl3.sh). */
    SDL_Event resized;
    SDL_zero(resized);
    resized.type = SDL_EVENT_WINDOW_RESIZED;
    resized.window.windowID = window->id;
    resized.window.data1 = width;
    resized.window.data2 = height;
    SDL_PushEvent(&resized);
""")

# ⚠️ **백그라운드에서는 이벤트를 펌프하는 스레드를 세운다.**
#    iOS 는 백그라운드 앱의 GPU 작업을 거부하고, MoltenVK 는 그걸 장치 손실로 본다.
#    홈으로 나가거나 화면을 잠그면 게임이 그대로 죽었다:
#      Lost VkDevice … Insufficient Permission (to submit GPU work from background)
#      GpuDeviceLossException: VK_ERROR_DEVICE_LOST: Failed to wait for semaphore
#    (GL 경로는 ANGLE 이 실패를 삼켜서 안 드러났다.)
#    26.3 은 SDL_EVENT_WILL_ENTER_BACKGROUND 를 보지 않는다. 대신 렌더 스레드가 매 프레임
#    SDL_PollEvent 로 이벤트를 펌프하므로, 거기서 세우면 그리기도 함께 멈춘다.
#    SDL 은 WillResignActive → WillEnterBackground, DidBecomeActive → DidEnterForeground 로
#    짝지어 부른다(SDL_uikitevents.m) — 알림 센터를 내리는 것만으로도 멈췄다 풀린다.
#    UIKit 메인 스레드는 세우지 않는다. 풀어 줄 알림을 받는 스레드다.
patch("src/events/SDL_events.c",
      "static void SDL_PumpEventsInternal(bool push_sentinel)\n{\n",
      """#ifdef SDL_PLATFORM_IOS
/* FlameLauncher: 백그라운드에서 렌더 스레드를 세운다(Scripts/build-sdl3.sh). */
#include <pthread.h>
static pthread_mutex_t flame_bg_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t flame_bg_cond = PTHREAD_COND_INITIALIZER;
static bool flame_bg;

void FLAME_SetBackground(bool background)
{
    pthread_mutex_lock(&flame_bg_lock);
    flame_bg = background;
    pthread_cond_broadcast(&flame_bg_cond);
    pthread_mutex_unlock(&flame_bg_lock);
}

static void FLAME_WaitWhileBackground(void)
{
    if (pthread_main_np()) {
        return;
    }
    pthread_mutex_lock(&flame_bg_lock);
    while (flame_bg) {
        pthread_cond_wait(&flame_bg_cond, &flame_bg_lock);
    }
    pthread_mutex_unlock(&flame_bg_lock);
}
#endif

static void SDL_PumpEventsInternal(bool push_sentinel)
{
#ifdef SDL_PLATFORM_IOS
    FLAME_WaitWhileBackground();
#endif
""")
patch("src/video/SDL_video.c",
      "void SDL_OnApplicationWillEnterBackground(void)\n{\n",
      """#ifdef SDL_PLATFORM_IOS
extern void FLAME_SetBackground(bool background);
#endif
void SDL_OnApplicationWillEnterBackground(void)
{
#ifdef SDL_PLATFORM_IOS
    FLAME_SetBackground(true);
#endif
""")
patch("src/video/SDL_video.c",
      "void SDL_OnApplicationDidEnterForeground(void)\n{\n",
      """void SDL_OnApplicationDidEnterForeground(void)
{
#ifdef SDL_PLATFORM_IOS
    FLAME_SetBackground(false);
#endif
""")

# ── FlameLauncher: iOS 의 GL 경로를 EAGL → EGL(ANGLE=MobileGlues)로 ─────────────
#
# 마인크래프트 26.3 의 GlBackend.loadLibrary 는 LWJGL 이 연 GL 파일 경로를 그대로 SDL 에
# 넘긴다. 상류 uikit 드라이버는 경로가 오면 무조건 실패를 돌려주므로 GL 백엔드를 아예 못
# 만들고, 게임은 Vulkan 으로 떨어진다. 그러면 GL 전용인 Iris 가 컨텍스트 없이 호출해 죽는다.
# MobileGlues(iOS)는 ANGLE 을 품고 EGL 심볼을 전부 내보내므로 SDL 의 범용 EGL 경로에 물린다.
patch("CMakeLists.txt",
      '        set(SDL_FRAMEWORK_OPENGLES 1)\n        set(SDL_VIDEO_OPENGL_ES 1)',
      '        set(SDL_FRAMEWORK_OPENGLES 1)\n        set(SDL_VIDEO_OPENGL_ES 1)\n        set(SDL_VIDEO_OPENGL_EGL 1)   # FlameLauncher: ANGLE 연결용')

patch("src/video/uikit/SDL_uikitopengles.m",
      '#include "SDL_uikitwindow.h"',
      '#include "SDL_uikitwindow.h"\n'
      '#include "SDL_uikitmetalview.h"\n'
      '#ifdef SDL_VIDEO_OPENGL_EGL\n'
      '#include "../SDL_egl_c.h"\n'
      '#include <pthread.h>\n'
      '#include <dispatch/dispatch.h>\n'
      '#define FLAME_EGL_SURFACE_PROP "flame.egl.surface"\n'
      '#define FLAME_EGL_VIEW_PROP "flame.egl.view"\n'
      '#endif')

patch("src/video/uikit/SDL_uikitopengles.m",
      "    /* We shouldn't pass a path to this function, since we've already loaded the",
      '#ifdef SDL_VIDEO_OPENGL_EGL\n'
      '    /* FlameLauncher: 경로가 오면 그 파일(MobileGlues=ANGLE)에서 EGL 을 연다. */\n'
      '    if (path && *path) {\n'
      '        /* ⚠️ SDL 내부 로더는 GL 라이브러리를 SDL_HINT_OPENGL_LIBRARY 에서 찾는데,\n'
      '         *    그 값이 LWJGL 쪽 **경로 목록**(…/lwjgl341:/…)으로 덮여 있어 로딩이 실패한다.\n'
      '         *    26.3 이 넘겨준 파일 경로로 다시 박아 같은 파일을 열게 한다. */\n'
      '        SDL_SetHintWithPriority(SDL_HINT_OPENGL_LIBRARY, path, SDL_HINT_OVERRIDE);\n'
      '        bool flame_ok = SDL_EGL_LoadLibrary(_this, path, EGL_DEFAULT_DISPLAY, 0);\n'
      '        fprintf(stderr, "[FlameEGL] GL 백엔드 준비 %s (%s)\\n",\n'
      '                flame_ok ? "성공" : "실패", flame_ok ? path : SDL_GetError());\n'
      '        fflush(stderr);\n'
      '        return flame_ok;\n'
      '    }\n'
      '#endif\n'
      "    /* We shouldn't pass a path to this function, since we've already loaded the")

# 창별 EGL 표면 — **창을 만들 때가 아니라 쓸 때** 만든다. 26.3 은 숨은 유틸리티 창으로
# 컨텍스트를 먼저 만들고, 한참 뒤에 진짜 게임 창을 만든 다음 그 창으로 MakeCurrent 한다.
# (컨텍스트 생성 때 만든 표면 하나로 버티면 게임 창에는 아무것도 안 그려진다)
patch("src/video/uikit/SDL_uikitopengles.m",
      'SDL_FunctionPointer UIKit_GL_GetProcAddress(SDL_VideoDevice *_this, const char *proc)\n{',
      '#ifdef SDL_VIDEO_OPENGL_EGL\n'
      'static EGLSurface flame_egl_surface(SDL_VideoDevice *_this, SDL_Window *window)\n'
      '{\n'
      '    if (!window) {\n'
      '        return EGL_NO_SURFACE;\n'
      '    }\n'
      '    SDL_PropertiesID props = SDL_GetWindowProperties(window);\n'
      '    EGLSurface surface = (EGLSurface)SDL_GetPointerProperty(props, FLAME_EGL_SURFACE_PROP, NULL);\n'
      '    if (surface) {\n'
      '        return surface;\n'
      '    }\n'
      '    if (!window->internal) {\n'
      '        /* 화면 없는 숨은 유틸리티 창(UIKit_CreateWindow 패치) → pbuffer. */\n'
      '        surface = SDL_EGL_CreateOffscreenSurface(_this,\n'
      '                                                 window->w > 0 ? window->w : 1,\n'
      '                                                 window->h > 0 ? window->h : 1);\n'
      '    } else {\n'
      '        /* 뷰 생성은 메인 스레드여야 한다 — 26.3 은 렌더 스레드에서 부른다. */\n'
      '        __block SDL_MetalView view = NULL;\n'
      '        if (pthread_main_np() != 0) {\n'
      '            view = UIKit_Metal_CreateView(_this, window);\n'
      '        } else {\n'
      '            dispatch_sync(dispatch_get_main_queue(), ^{\n'
      '                view = UIKit_Metal_CreateView(_this, window);\n'
      '            });\n'
      '        }\n'
      '        if (!view) {\n'
      '            return EGL_NO_SURFACE;\n'
      '        }\n'
      '        surface = SDL_EGL_CreateSurface(_this, window,\n'
      '                                        (NativeWindowType)UIKit_Metal_GetLayer(_this, view));\n'
      '        if (surface == EGL_NO_SURFACE) {\n'
      '            UIKit_Metal_DestroyView(_this, view);\n'
      '            return EGL_NO_SURFACE;\n'
      '        }\n'
      '        SDL_SetPointerProperty(props, FLAME_EGL_VIEW_PROP, view);\n'
      '    }\n'
      '    if (surface != EGL_NO_SURFACE) {\n'
      '        SDL_SetPointerProperty(props, FLAME_EGL_SURFACE_PROP, surface);\n'
      '    }\n'
      '    return surface;\n'
      '}\n'
      '#endif\n'
      '\n'
      'SDL_FunctionPointer UIKit_GL_GetProcAddress(SDL_VideoDevice *_this, const char *proc)\n{')

patch("src/video/uikit/SDL_uikitopengles.m",
      "    /* Look through all SO's for the proc symbol.  Here's why:",
      '#ifdef SDL_VIDEO_OPENGL_EGL\n'
      '    /* FlameLauncher: EGL 로 열었으면 그쪽에서 찾는다 — 26.3 은 여기서 나온\n'
      '     * glGetError 주소가 LWJGL 쪽과 같아야 GL 백엔드를 받아들인다. */\n'
      '    if (_this->egl_data) {\n'
      '        return SDL_EGL_GetProcAddressInternal(_this, proc);\n'
      '    }\n'
      '#endif\n'
      "    /* Look through all SO's for the proc symbol.  Here's why:")

patch("src/video/uikit/SDL_uikitopengles.m",
      'bool UIKit_GL_SwapWindow(SDL_VideoDevice *_this, SDL_Window *window)\n{\n    @autoreleasepool {',
      'bool UIKit_GL_SwapWindow(SDL_VideoDevice *_this, SDL_Window *window)\n{\n'
      '#ifdef SDL_VIDEO_OPENGL_EGL\n'
      '    if (_this->egl_data) {\n'
      '        return SDL_EGL_SwapBuffers(_this, flame_egl_surface(_this, window));\n'
      '    }\n'
      '#endif\n'
      '    @autoreleasepool {')

patch("src/video/uikit/SDL_uikitopengles.m",
      'bool UIKit_GL_MakeCurrent(SDL_VideoDevice *_this, SDL_Window *window, SDL_GLContext context)\n{\n    @autoreleasepool {',
      'bool UIKit_GL_MakeCurrent(SDL_VideoDevice *_this, SDL_Window *window, SDL_GLContext context)\n{\n'
      '#ifdef SDL_VIDEO_OPENGL_EGL\n'
      '    if (_this->egl_data) {\n'
      '        EGLSurface surface = flame_egl_surface(_this, window);\n'
      '        if (SDL_EGL_MakeCurrent(_this, surface, context)) {\n'
      '            return true;\n'
      '        }\n'
      '        /* ⚠️ ANGLE 은 컨텍스트가 다른 스레드에 물려 있으면 EGL_BAD_ACCESS 를 낸다.\n'
      '         *    MobileGlues 가 초기화하며 자기 컨텍스트를 걸어둔 상태라 처음 한 번은 반드시\n'
      '         *    걸린다 — 현재 바인딩을 풀고 다시 시도한다. */\n'
      '        _this->egl_data->eglMakeCurrent(_this->egl_data->egl_display,\n'
      '                                        EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);\n'
      '        bool flame_again = SDL_EGL_MakeCurrent(_this, surface, context);\n'
      '        if (!flame_again) {\n'
      '            fprintf(stderr, "[FlameEGL] MakeCurrent 실패 (%s)\\n", SDL_GetError());\n'
      '            fflush(stderr);\n'
      '        }\n'
      '        return flame_again;\n'
      '    }\n'
      '#endif\n'
      '    @autoreleasepool {')

patch("src/video/uikit/SDL_uikitopengles.m",
      'SDL_GLContext UIKit_GL_CreateContext(SDL_VideoDevice *_this, SDL_Window *window)\n{\n    @autoreleasepool {',
      'SDL_GLContext UIKit_GL_CreateContext(SDL_VideoDevice *_this, SDL_Window *window)\n{\n'
      '#ifdef SDL_VIDEO_OPENGL_EGL\n'
      '    if (_this->egl_data) {\n'
      '        @autoreleasepool {\n'
      '            EGLSurface surface = flame_egl_surface(_this, window);\n'
      '            if (surface == EGL_NO_SURFACE) {\n'
      '                return NULL;\n'
      '            }\n'
      '            SDL_GLContext context = SDL_EGL_CreateContext(_this, surface);\n'
      '            return context;\n'
      '        }\n'
      '    }\n'
      '#endif\n'
      '    @autoreleasepool {')

# ⚠️ 이벤트 펌프가 매 프레임 부르는 EAGL 복구 코드 — EGL 컨텍스트에서는 **반드시** 꺼야 한다.
#    SDL_GLContext 를 EAGLContext 로 __bridge 캐스팅해 ARC 가 retain 을 거는데, 우리 컨텍스트는
#    ObjC 객체가 아니라 EGL 핸들(0x2)이다. 실측: objc_retain+0x8 에서 SIGSEGV
#    (SDL_PumpEventsInternal → UIKit_PumpEvents → UIKit_GL_RestoreCurrentContext).
patch("src/video/uikit/SDL_uikitopengles.m",
      'void UIKit_GL_RestoreCurrentContext(void)\n{\n    @autoreleasepool {',
      'void UIKit_GL_RestoreCurrentContext(void)\n{\n'
      '#ifdef SDL_VIDEO_OPENGL_EGL\n'
      '    {\n'
      '        SDL_VideoDevice *flame_this = SDL_GetVideoDevice();\n'
      '        if (flame_this && flame_this->egl_data) {\n'
      '            return;   /* FlameLauncher: EGL 컨텍스트는 EAGL 이 아니다. */\n'
      '        }\n'
      '    }\n'
      '#endif\n'
      '    @autoreleasepool {')

patch("src/video/uikit/SDL_uikitopengles.m",
      'bool UIKit_GL_DestroyContext(SDL_VideoDevice *_this, SDL_GLContext context)\n{',
      'bool UIKit_GL_DestroyContext(SDL_VideoDevice *_this, SDL_GLContext context)\n{\n'
      '#ifdef SDL_VIDEO_OPENGL_EGL\n'
      '    if (_this->egl_data) {\n'
      '        return SDL_EGL_DestroyContext(_this, context);\n'
      '    }\n'
      '#endif')

# 창 두 개 — 26.3 의 GL 백엔드는 컨텍스트용 "숨은 유틸리티 창"(UTILITY|HIDDEN)을 먼저
# 만들고, 그 다음 진짜 게임 창을 만든다. uikit 백엔드는 디스플레이당 창 하나만 허용해서
# 두 번째에서 막혔다:
#   BackendCreationException: Failed to create window for OpenGL after creating context
#   (SDL 오류는 **스레드별**이라 렌더 스레드에는 "Only one window allowed per display."
#    대신 예전 오류가 남아 있었다 — SDL_CreateWindow 를 메인으로 넘기기 때문이다)
# 안드로이드와 같은 방식으로 푼다: 숨은 쪽은 화면이 필요 없으니 UIWindow 없이 만들고
# GL 표면은 pbuffer 로 준다(위 UIKit_GL_CreateContext 패치). 화면은 진짜 창이 가져간다.
# ⚠️ **UTILITY 로만** 가른다 — 게임 창도 HIDDEN 으로 만들어진 뒤 나중에 표시된다.
patch("src/video/uikit/SDL_uikitwindow.m",
      '        // We currently only handle a single window per display on iOS\n'
      '        for (other = _this->windows; other; other = other->next) {\n'
      '            if (other != window && SDL_GetVideoDisplayForWindow(other) == display) {',
      '        /* FlameLauncher: 숨은 유틸리티 창은 UIWindow 없이 만든다(자세한 사정은\n'
      '           Scripts/build-sdl3.sh 주석). internal 이 NULL 인 창 = 오프스크린. */\n'
      '        if (window->flags & SDL_WINDOW_UTILITY) {\n'
      '            window->internal = NULL;\n'
      '            return true;\n'
      '        }\n'
      '\n'
      '        // We currently only handle a single window per display on iOS\n'
      '        for (other = _this->windows; other; other = other->next) {\n'
      '            /* ⚠️ 오프스크린 창(other->internal == NULL)은 화면을 안 쓰니 세지 않는다.\n'
      '               26.3 은 숨은 유틸리티 창을 끝까지 살려 두므로, 세면 진짜 게임 창이 막힌다. */\n'
      '            if (other != window && other->internal &&\n'
      '                SDL_GetVideoDisplayForWindow(other) == display) {')

patch("src/video/uikit/SDL_uikitwindow.m",
      'void UIKit_GetWindowSizeInPixels(SDL_VideoDevice *_this, SDL_Window *window, int *w, int *h)\n{\n    @autoreleasepool {',
      'void UIKit_GetWindowSizeInPixels(SDL_VideoDevice *_this, SDL_Window *window, int *w, int *h)\n{\n'
      '    if (!window->internal) {   /* FlameLauncher: 오프스크린 창은 요청한 크기 그대로. */\n'
      '        *w = window->w;\n'
      '        *h = window->h;\n'
      '        return;\n'
      '    }\n'
      '    @autoreleasepool {')

# ⚠️ 공용 SDL_GL_LoadLibrary 도 손봐야 한다. iOS 는 창을 만들 때 SDL 이 GL 을 **경로 없이**
#    먼저 열어 두는데(driver_loaded=1, driver_path=""), 26.3 은 그 뒤에 LWJGL 이 연 파일
#    경로로 다시 요청한다. 상류는 경로가 다르면 드라이버까지 가기도 전에 거절한다:
#      "OpenGL library already loaded"
#    → 경로가 오면 한 번은 그 경로로 다시 열게 한다(우리 uikit 드라이버가 EGL 로 받는다).
patch("src/video/SDL_video.c",
      '    if (_this->gl_config.driver_loaded) {\n'
      '        if (path && SDL_strcmp(path, _this->gl_config.driver_path) != 0) {\n'
      '            return SDL_SetError("OpenGL library already loaded");\n'
      '        }\n'
      '        result = true;',
      '    if (_this->gl_config.driver_loaded) {\n'
      '        if (path && SDL_strcmp(path, _this->gl_config.driver_path) != 0) {\n'
      '#ifdef SDL_PLATFORM_IOS\n'
      '            /* FlameLauncher: 경로가 오면 그 파일로 다시 연다(ANGLE=MobileGlues). */\n'
      '            if (!_this->GL_LoadLibrary) {\n'
      '                return SDL_DllNotSupported("OpenGL");\n'
      '            }\n'
      '            _this->gl_config.driver_loaded = 0;\n'
      '            result = _this->GL_LoadLibrary(_this, path);\n'
      '            if (result) {\n'
      '                ++_this->gl_config.driver_loaded;\n'
      '            }\n'
      '            return result;\n'
      '#else\n'
      '            return SDL_SetError("OpenGL library already loaded");\n'
      '#endif\n'
      '        }\n'
      '        result = true;')

SDLPATCH
}

build_ios() {
  echo "▸ iOS arm64"
  # ⚠️ **dylib** 으로 만든다. LWJGL 의 org.lwjgl.sdl.SDL 은 정적 심볼을 찾지 않고
  #    `Library.loadNative` 로 연다 — 즉 `Configuration.SDL_LIBRARY_NAME`
  #    (`-Dorg.lwjgl.sdl.libname`) 으로 가리킬 수 있는 **파일**이어야 한다.
  #    앱 번들 안의 dylib 은 iOS 에서도 dlopen 되며, 이미 libmobileglues.dylib 을
  #    같은 방식으로 쓰고 있다. 정적으로 링크하면 이 경로가 막힌다.
  patch_ios_mainthread "$WORK/src"

  cmake -S "$WORK/src" -B "$WORK/ios" "${COMMON[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF > "$WORK/ios-cfg.log" 2>&1 || {
      echo "  ✗ cmake 구성 실패:"; tail -20 "$WORK/ios-cfg.log" | sed 's/^/    /'; return 1; }
  # ⚠️ 출력을 버리지 않는다. 컴파일 오류가 여기로 나오는데 /dev/null 이면
  #    rc=1 만 남아서 무엇이 깨졌는지 알 수 없다(실제로 두 번 헤맸다).
  cmake --build "$WORK/ios" -j"$(sysctl -n hw.ncpu)" > "$WORK/ios-build.log" 2>&1 || {
      echo "  ✗ 빌드 실패:"; grep -E "error:" "$WORK/ios-build.log" | head -12 | sed 's/^/    /'; return 1; }

  local lib
  lib=$(find "$WORK/ios" -name "libSDL3*.dylib" -type f | head -1)
  [ -n "$lib" ] || { echo "  ✗ libSDL3 dylib 이 없습니다"; return 1; }

  # cmake 는 타깃을 틀려도 조용히 성공한다. 앱에 넣는 순간에야 알게 되므로 여기서 자른다.
  case "$(lipo -info "$lib")" in *arm64*) ;; *) echo "  ✗ arm64 가 아닙니다"; return 1 ;; esac
  local plats; plats=$(otool -l "$lib" | sed -n 's/^ *platform //p' | sort -u | tr '\n' ' ')
  case "$plats" in "2 ") ;; *) echo "  ✗ iOS 전용이 아닙니다 (platform=$plats)"; return 1 ;; esac

  # 26.3 이 실제로 부르는 것 중 대표 몇 개가 실려 있는지 확인한다.
  #
  # ⚠️ `nm ... | grep -q` 로 쓰면 안 된다. grep -q 는 찾자마자 끝나면서 nm 을 SIGPIPE 로
  #    죽이고, `set -o pipefail` 이 그걸 파이프라인 실패로 본다 — 심볼이 **있는데도**
  #    없다고 보고한다. (build-terracotta.sh 에 같은 함정을 적어 뒀는데 또 걸렸다)
  #    한 번만 읽어서 변수에 담고 거기서 찾는다.
  local syms; syms=$(nm -gU "$lib")
  # ⚠️ 번들 안에서 열리려면 install_name 이 @rpath 여야 한다. cmake 는 빌드 경로를
  #    박아 두므로 그대로 두면 기기에서 dlopen 이 실패한다.
  install_name_tool -id "@rpath/libSDL3.dylib" "$lib" 2>/dev/null || true
  for sym in _SDL_Init _SDL_CreateWindow _SDL_GL_CreateContext _SDL_GL_SwapWindow _SDL_PollEvent; do
    case "$syms" in *" T $sym"*) ;; *) echo "  ✗ $sym 없음"; return 1 ;; esac
  done

  mkdir -p "$ROOT/Runtime/SDL3"
  cp "$lib" "$ROOT/Runtime/SDL3/libSDL3.dylib"
  mkdir -p "$ROOT/Runtime/SDL3/include"
  cp -R "$WORK/src/include/SDL3" "$ROOT/Runtime/SDL3/include/"
  echo "  완료: Runtime/SDL3/libSDL3.dylib ($(du -h "$lib" | cut -f1))"
}

# ⚠️ Android: 데스크톱 GL 요청을 **GLES 로 접어 준다**.
#
#    26.3 은 Vulkan 이 안 되는 기기에서 OpenGL 백엔드로 폴백하는데, SDL 은 그때
#    "데스크톱 GL" 설정(EGL_OPENGL_BIT · eglBindAPI(EGL_OPENGL_API) · core profile)을
#    EGL 에 요구한다. 안드로이드 EGL 에는 그런 게 없다. 실측 로그:
#      BackendCreationException: Failed to create window for OpenGL context:
#        Couldn't find matching EGL config (eglChooseConfig failed)
#
#    안드로이드에서 데스크톱 GL 은 번역 계층(MobileGlues)이 GLES 위에 얹어 주는 것이고,
#    그 계층이 EGL 진입점도 직접 내보낸다. 그러니 EGL 에는 **ES 3 컨텍스트**를 달라고
#    해야 맞다 — GL 함수는 어차피 번역 계층에서 온다.
patch_android_gles() {
  local src="$1"
  python3 - "$src" <<'SDLPATCH'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
p = root / "src/video/SDL_egl.c"
s = p.read_text()

# 1) 설정 선택: 데스크톱 GL 요청이어도 EGL 에는 ES3 설정을 달라고 한다.
old = """    attribs[i++] = EGL_RENDERABLE_TYPE;
    if (_this->gl_config.profile_mask == SDL_GL_CONTEXT_PROFILE_ES) {"""
new = """    attribs[i++] = EGL_RENDERABLE_TYPE;
#ifdef SDL_PLATFORM_ANDROID
    /* FlameLauncher: 안드로이드에서 데스크톱 GL 은 번역 계층(MobileGlues)이 GLES 위에
       얹어 주는 것이다. EGL 에는 ES3 설정을 달라고 해야 한다.
       ⚠️ gl_config 는 **건드리지 않는다.** SDL_GL_GetAttribute 는 이 값을 그대로 돌려주고,
          마인크래프트는 그걸로 "요청한 GL 버전이 나왔는지"를 판정한다(GlDevice). 덮어쓰면
          "Failed to create OpenGL 3.3 context, got OpenGL 3.2" 로 거절당한다. */
    if (_this->gl_config.profile_mask != SDL_GL_CONTEXT_PROFILE_ES) {
        attribs[i++] = EGL_OPENGL_ES3_BIT_KHR;
        _this->egl_data->eglBindAPI(EGL_OPENGL_ES_API);
    } else
#endif
    if (_this->gl_config.profile_mask == SDL_GL_CONTEXT_PROFILE_ES) {"""
assert old in s, "ChooseConfig 앵커를 못 찾았습니다"
s = s.replace(old, new, 1)

# 2) 컨텍스트 생성: EGL 에 넘기는 값만 ES 3.2 로. 보고값(gl_config)은 그대로 둔다.
old2 = """    bool profile_es = (profile_mask == SDL_GL_CONTEXT_PROFILE_ES);"""
new2 = """    bool profile_es = (profile_mask == SDL_GL_CONTEXT_PROFILE_ES);
#ifdef SDL_PLATFORM_ANDROID
    /* FlameLauncher: 설정 선택과 같은 이유로 컨텍스트도 ES 3.2 로 만든다.
       요청한 GL 4.x 숫자를 그대로 ES 로 넘기면 eglCreateContext 가 EGL_BAD_MATCH 다.
       core/forward-compatible 플래그도 ES 에는 못 얹는다. 지역 변수만 바꾼다. */
    const bool flame_forced_es = !profile_es;
    if (flame_forced_es) {
        profile_mask = SDL_GL_CONTEXT_PROFILE_ES;
        profile_es = true;
        major_version = 3;
        minor_version = 2;
    }
#else
    const bool flame_forced_es = false;
#endif"""
assert old2 in s, "CreateContext 앵커를 못 찾았습니다"
s = s.replace(old2, new2, 1)

old3 = """            // SDL flags match EGL flags.
            if (_this->gl_config.flags != 0) {"""
new3 = """            // SDL flags match EGL flags.
            if (_this->gl_config.flags != 0 && !flame_forced_es) {"""
assert old3 in s, "flags 앵커를 못 찾았습니다"
s = s.replace(old3, new3, 1)

p.write_text(s)
print("  SDL_egl.c: 데스크톱 GL → ES 3.2 (보고값은 유지)")

# 3) 창 두 개 — 26.3 의 GL 백엔드는 컨텍스트용 "숨은 유틸리티 창"을 먼저 만들고
#    그 다음 진짜 게임 창을 만든다. 업스트림 안드로이드 백엔드는 창을 하나만 허용해서
#    여기서 막혔다(BackendCreationException: Android only supports one window).
#    숨은 쪽은 화면이 필요 없으니 pbuffer 로 만들어 주고, 안드로이드 Surface 는
#    진짜 창이 가져가게 둔다.
w = root / "src/video/android/SDL_androidwindow.c"
t = w.read_text()

old_w = """    if (Android_Window) {
        result = SDL_SetError("Android only supports one window");
        goto endfunction;
    }"""
new_w = """    /* FlameLauncher: 마인크래프트 26.3 의 GL 백엔드는 컨텍스트용 **숨은 유틸리티 창**을
       먼저 만들고, 그 다음 진짜 게임 창을 만든다. 업스트림은 창을 하나만 허용한다.
       ⚠️ 순서가 중요하다 — 숨은 창이 **먼저** 오므로 "이미 창이 있으면" 으로 가르면
          숨은 창이 화면을 차지하고 게임 창이 오프스크린으로 밀린다(실측: 검은 화면 · 세로 고정).
          그래서 창의 종류로 가른다.
       ⚠️ **UTILITY 로만** 가른다. 게임 창도 HIDDEN 으로 만들어진 뒤 나중에 표시되므로,
          HIDDEN 까지 보면 게임 창마저 오프스크린이 된다 — 실측: 게임은 스왑을 계속 성공하는데
          대상이 전부 pbuffer 라 화면이 검었다. 숨은 유틸리티 창만 UTILITY 를 단다. */
    if (window->flags & SDL_WINDOW_UTILITY) {
        {
            SDL_WindowData *offscreen = (SDL_WindowData *)SDL_calloc(1, sizeof(*offscreen));
            if (!offscreen) {
                result = false;
                goto endfunction;
            }
            offscreen->native_window = NULL;
#ifdef SDL_VIDEO_OPENGL_EGL
            if (window->flags & SDL_WINDOW_OPENGL) {
                offscreen->egl_surface = SDL_EGL_CreateOffscreenSurface(_this,
                                                                        window->w > 0 ? window->w : 1,
                                                                        window->h > 0 ? window->h : 1);
                if (offscreen->egl_surface == EGL_NO_SURFACE) {
                    SDL_free(offscreen);
                    result = false;
                    goto endfunction;
                }
            }
#endif
            window->internal = offscreen;
            goto endfunction;
        }
    }

    if (Android_Window) {
        result = SDL_SetError("Android only supports one window");
        goto endfunction;
    }"""
assert old_w in t, "CreateWindow 앵커를 못 찾았습니다"
t = t.replace(old_w, new_w, 1)

old_d = """    if (window == Android_Window) {
        Android_Window = NULL;

        if (window->internal) {"""
new_d = """    if (window != Android_Window) {
        /* FlameLauncher: 위에서 만든 오프스크린(숨은) 창 정리. */
        if (window->internal) {
            SDL_WindowData *data = window->internal;
#ifdef SDL_VIDEO_OPENGL_EGL
            if (data->egl_surface != EGL_NO_SURFACE) {
                SDL_EGL_DestroySurface(_this, data->egl_surface);
            }
#endif
            SDL_free(window->internal);
            window->internal = NULL;
        }
    }

    if (window == Android_Window) {
        Android_Window = NULL;

        if (window->internal) {"""
assert old_d in t, "DestroyWindow 앵커를 못 찾았습니다"
t = t.replace(old_d, new_d, 1)

# 4) iOS 와 같은 패치 — 창을 만든 뒤 **실제 표면 크기를 RESIZED 로 알린다**.
#    26.3 의 Window 는 --width/--height(854x480)로 시작해 RESIZED 로만 크기를 고친다.
#    안드로이드 백엔드는 자바 쪽 통지(surfaceChanged)로 받은 크기를 쓰는데, 우리 구조에서는
#    그 통지가 창 생성보다 늦거나 오지 않아 창이 854x480 에 머문다(실측) — iOS 에서
#    같은 이유로 게임이 끝까지 854x480 이라 믿었던 것과 똑같다.
#    크기는 자바를 거치지 않고 표면(ANativeWindow)에서 직접 읽는다.
old_r = """    SDL_SetWindowSafeAreaInsets(window, Android_SafeInsetLeft, Android_SafeInsetRight, Android_SafeInsetTop, Android_SafeInsetBottom);"""
new_r = """    SDL_SetWindowSafeAreaInsets(window, Android_SafeInsetLeft, Android_SafeInsetRight, Android_SafeInsetTop, Android_SafeInsetBottom);

    /* FlameLauncher: 실제 표면 크기로 맞추고 앱에 알린다(Scripts/build-sdl3.sh — iOS 패치와 같은 이유). */
    {
        const int sw = ANativeWindow_getWidth(data->native_window);
        const int sh = ANativeWindow_getHeight(data->native_window);
        if (sw > 0 && sh > 0) {
            window->w = sw;
            window->h = sh;
            SDL_Event resized;
            SDL_zero(resized);
            resized.type = SDL_EVENT_WINDOW_RESIZED;
            resized.window.windowID = window->id;
            resized.window.data1 = sw;
            resized.window.data2 = sh;
            SDL_PushEvent(&resized);
            resized.type = SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
            SDL_PushEvent(&resized);
        }
    }"""
assert old_r in t, "SafeAreaInsets 앵커를 못 찾았습니다"
t = t.replace(old_r, new_r, 1)

w.write_text(t)
print("  SDL_androidwindow.c: 숨은 유틸리티 창은 오프스크린으로")
print("  SDL_androidwindow.c: 창 생성 직후 실제 크기로 RESIZED")
SDLPATCH
}

build_android() {
  echo "▸ Android arm64-v8a"
  local ndk="${ANDROID_NDK_HOME:-}"
  if [ -z "$ndk" ]; then
    ndk=$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | sort -V | tail -1 || true)
  fi
  [ -n "$ndk" ] && [ -d "$ndk" ] || { echo "  ✗ NDK 를 찾지 못했습니다 (ANDROID_NDK_HOME)"; return 1; }
  echo "  NDK: ${ndk##*/}"

  # ⚠️ 안드로이드는 공유 라이브러리다. LWJGL 이 jniLibs 에서 dlopen 한다
  #    (lwjgl-sdl 의 natives jar 도 libSDL3.so 하나만 들고 있다).
  patch_android_gles "$WORK/src"

  # ⚠️ 실패해도 조용하면 안 된다 — 로그로 받아 두고 실패할 때만 꼬리를 찍는다
  #    (CI 에서 cmake 구성이 깨졌는데 경고만 보이고 이유가 안 보였다).
  local log="$WORK/android-cmake.log"
  if ! cmake -S "$WORK/src" -B "$WORK/android" "${COMMON[@]}" \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF >"$log" 2>&1; then
    echo "  ✗ cmake 구성 실패:"; tail -25 "$log"; return 1
  fi
  if ! cmake --build "$WORK/android" -j"$(sysctl -n hw.ncpu)" >"$log" 2>&1; then
    echo "  ✗ 빌드 실패:"; tail -25 "$log"; return 1
  fi

  local so="$WORK/android/libSDL3.so"
  [ -f "$so" ] || { echo "  ✗ libSDL3.so 가 없습니다"; return 1; }
  case "$(file "$so")" in *aarch64*) ;; *) echo "  ✗ aarch64 가 아닙니다"; return 1 ;; esac

  mkdir -p "$ROOT/Runtime/SDL3/android/arm64-v8a"
  cp "$so" "$ROOT/Runtime/SDL3/android/arm64-v8a/libSDL3.so"
  echo "  완료: Runtime/SDL3/android/arm64-v8a/libSDL3.so ($(du -h "$so" | cut -f1))"
}

case "$TARGET" in
  ios)     build_ios ;;
  android) build_android ;;
  all)     build_ios; build_android ;;
  *)       echo "사용법: $0 [ios|android|all]"; exit 2 ;;
esac
