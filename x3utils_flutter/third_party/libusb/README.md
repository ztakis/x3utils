# libusb 1.0

The dormant native swdart transport requires libusb 1.0 when it is eventually
enabled for desktop builds. Windows release builds package the DLL beside
`x3utils.exe`, where `transport_native.dart` looks first, and copy this README
plus `LICENSE-LGPL-2.1.txt` to `licenses/libusb/`.

The Windows binary in `windows/libusb-1.0.dll` was preserved from
`swdart_at32/demo/windows` before the standalone tree is retired.

- Product version: 1.0.30.12037
- SHA-256: `5BD409849825009B6FE25861A6147F76D256AAB248F07049D78387E3BFF12D94`
- License: LGPL-2.1-or-later; see `LICENSE-LGPL-2.1.txt`
- Upstream release and corresponding source:
  `https://github.com/libusb/libusb/releases/tag/v1.0.30`

Packaging the runtime does not enable native swdart. Desktop continues to use
the existing OpenOCD backend until backend routing and packaged hardware
verification are handled as separate phases.

The macOS package reuses the universal libusb dylib already distributed with
the bundled xPack OpenOCD payload:

- Source: `native/macos/oocd/libexec/libusb-1.0.0.dylib`
- Packaged runtime:
  `x3utils.app/Contents/MacOS/native/macos/oocd/libexec/libusb-1.0.0.dylib`
- Architectures: x86_64 and arm64
- SHA-256: `234EF4C2BD59F5F499F52323DFB94CCB8123A610C87B5499D7115FD45D5B89BC`
- Distribution provenance:
  `https://github.com/xpack-dev-tools/openocd-xpack/releases/tag/v0.12.0-7`

The macOS package copies this README and `LICENSE-LGPL-2.1.txt` to
`x3utils.app/Contents/Resources/licenses/libusb/`. The application-local dylib
remains part of the signed native payload; no second copy is added.

Linux intentionally uses the distribution's libusb runtime instead of copying
a build-host `.so` into the AppImage. The native transport searches the normal
`libusb-1.0.so.0` and `libusb-1.0.so` sonames, its app-local `lib/` fallback,
and common x86_64 system locations. Debian, Ubuntu and Mint provide the runtime
as `libusb-1.0-0`.

Loading libusb is separate from permission to open an ST-LINK. Linux packages
also require appropriate udev rules; the existing OpenOCD rules are preserved
at `native/linux/oocd/contrib/60-openocd.rules`. AppImage loading and ST-LINK
access through native swdart remain pending Linux-host verification.
