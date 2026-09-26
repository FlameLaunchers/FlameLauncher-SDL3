Built from SDL `@REF@` with the mobile patches in `Scripts/build-sdl3.sh` (the README says what each one fixes).

| Asset | Platform |
|---|---|
| `libSDL3-ios-arm64.dylib` | iOS arm64 |
| `libSDL3-android-arm64-v8a.so` | Android arm64-v8a |

Point LWJGL at it with `-Dorg.lwjgl.sdl.libname=<absolute path>` — `org.lwjgl.sdl.SDL` opens the file, it does not look for symbols, so it has to be a real library on disk.
