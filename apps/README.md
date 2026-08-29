# apps

Android applications for the APEX kernel.

## apex-control

A Jetpack Compose app that provides a UI for controlling the apex kernel
state machine. Communicates with the `apex-bridge` daemon via Unix domain
socket at `/dev/socket/apex-bridge`.

### Features

- Gaming mode toggle (writes to /proc/apex/policy)
- Real-time status display (screen, charging, audio, thermal)
- Governor tunable display
- Incident log viewer (/proc/apex/incidents)
- Thermal temperature monitor

### Build

```bash
cd apex-control
./gradlew assembleRelease
```

Requires Android SDK 34+ and Kotlin 1.9+.
