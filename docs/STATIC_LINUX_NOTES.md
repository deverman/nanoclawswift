# Static Linux Notes (Deferred)

These notes capture what we learned about static Linux builds. This work is deferred until after the slim container path is complete.

## Why static Linux came up

Apple containers run Linux. macOS binaries won’t execute inside Linux containers ("exec format error"). A static Linux binary would allow us to run without needing a Swift toolchain in the container.

## Status

- Deferred. We are staying on the `swift:6.2.3-slim` container for now.

## What we learned

1. **Static Linux SDK install**
   - Swift provides a Static Linux SDK bundle for 6.2.3.
   - Download the SDK and install it with a checksum.
   - Example (checksum required):
     ```bash
     swift sdk install <bundle>.tar.gz --checksum <checksum>
     ```

2. **Cross-compile target**
   - Once installed, build with:
     ```bash
     swift build --swift-sdk aarch64-swift-linux-musl -c release
     ```

3. **Musl vs Glibc**
   - The static SDK uses Musl, not Glibc.
   - Dependencies that import `Glibc` must be updated to handle `Musl`:
     ```swift
     #if canImport(Darwin)
     import Darwin
     #elseif canImport(Glibc)
     import Glibc
     #elseif canImport(Musl)
     import Musl
     #endif
     ```

4. **SwiftPM editable dependencies**
   - You may need to patch dependencies for Musl.
   - If you edit a dependency, remember to unedit it after the build.

## Why we paused this work

- The slim container path is sufficient for current release goals.
- Static Linux introduces extra complexity (patching dependencies, large SDK download).

## Next time

If/when we resume static Linux:

- Use a fast connection (SDK bundle is large).
- Patch any Glibc-only dependencies to support Musl.
- Automate the patching and build steps in a script (not committed until ready).
