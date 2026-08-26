# Custom apps

Apex Control (Compose, primary) + NFCForge (NFC attack module) + PTK TUI
(terminal fallback). **No code is written yet.**

## Plan

| Path | Purpose |
| :--- | :--- |
| `apex-control/build.gradle.kts` | Gradle build (Kotlin/Compose) |
| `apex-control/src/main/AndroidManifest.xml` | Manifest |
| `apex-control/src/main/kotlin/...` | Sources (will go here) |
| `nfcforge/` | NFC attack module (sources, MIFARE keys) |
| `ptk-tui/` | TUI module (Python/curses) |

## Status

Empty. Theory only. Apex Control will be the only app visible in the launcher;
NFCForge and PTK TUI are launched from within it.
