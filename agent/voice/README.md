# Voice Subsystem (T6)

## Overview

On-device voice input using whisper.cpp for speech-to-text (STT) and
a lightweight VAD-based wake-word detector.

## Components

| Component | Description |
|-----------|-------------|
| `VoiceManager.java` | Java API for wake-word + STT |
| `libwhisper_jni/whisper_jni.c` | JNI bridge to whisper.cpp |
| `build-whisper.sh` | Cross-compile whisper.cpp for arm64 |

## CPU Budget on A73 (4x 2.0GHz + 4x 1.7GHz A53)

| Operation | Cores | CPU Usage | Latency |
|-----------|-------|-----------|---------|
| Wake-word VAD | 1x A53 | 2-3% | Continuous |
| Whisper STT (tiny.en) | 2x A73 | 15-25% | 1-3s for short phrase |
| Idle (no audio) | 0 | 0% | - |

## Memory

| Component | Size |
|-----------|------|
| Whisper tiny.en model | ~75MB (ggml) |
| Audio ring buffer | 128KB (4s @ 16kHz 16-bit) |
| Total voice subsystem | ~80MB |

## Privacy

- All audio processed on-device, never transmitted
- Audio buffer cleared after each transcription
- Wake-word detector runs only when screen on or agent active
- No cloud speech services, no audio recording without wake-word trigger

## Wake-Word Detection

Simple VAD (Voice Activity Detection) with energy threshold:
- RMS > 300 → voice detected
- On voice detection → start Whisper STT
- Future: add keyword spotting model (e.g., "Hey Apex") for lower false positive rate

## Model

- **Model**: ggml-tiny.en (English-only, 39M params)
- **Download**: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin`
- **Storage**: `/data/local/tmp/models/ggml-tiny.en.bin`
- **Threads**: 2 (A73 cores for speed)
