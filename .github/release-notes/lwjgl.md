LWJGL `@REF@` natives for mobile, built from source. libffi is built too and linked statically into `liblwjgl` — 3.4.x rebuilt its callback layer on top of it.

| Asset | Contents |
|---|---|
| `lwjgl-ios-arm64.zip` | `liblwjgl`, `liblwjgl_opengl`, `liblwjgl_stb`, `liblwjgl_tinyfd` (.dylib) |
| `lwjgl-android-arm64-v8a.zip` | `liblwjgl`, `liblwjgl_opengl`, `liblwjgl_stb`, `liblwjgl_vma` (.so) |

The jar and the natives must be the same version: a 3.4.3 jar on 3.4.1 natives dies in class init with `UnsatisfiedLinkError: MemoryUtil.ngetPageSize()`.
