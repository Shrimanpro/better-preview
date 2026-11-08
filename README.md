# Better Preview

A native macOS document viewer: Apple Preview's features driven like zathura (vim keys, `:` command line, themes with page recoloring, an rc file). Swift + AppKit + PDFKit, no third-party dependencies.

## Build

```sh
swift build                 # debug build
swift test                  # unit tests
scripts/bundle.sh           # release build -> "build/Better Preview.app" (ad-hoc signed)
open -a "build/Better Preview.app" file.pdf
```

Requires macOS 27 and the Swift toolchain.

## Configuration

Config lives at `~/.config/better-preview/rc` (zathurarc syntax; `BP_RC=<path>` overrides it) and reloads when saved.

```
set theme catppuccin-mocha
set recolor true
map <C-j> page-next
```

## Testing

- `swift scripts/make-test-assets.swift` writes `build/test-assets/` (500-page PDF, short PDF, images).
- `BP_SELFTEST=all` runs the in-app self-tests.
- `BP_SCRIPT="sleep 1;keys 5j;quit"` drives a window headlessly and prints `STATUS` lines.
