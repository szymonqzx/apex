# 06 — Agent Remote & Voice

## Remote Model Proxy

### Architecture

The agent has no network access (SELinux neverallow). Remote inference goes through a separate proxy process with its own SELinux domain (`apex_remote_proxy`) that has network access.

```
apexagentd (no network)
  → localhost:9879 (TCP)
    → RemoteProxyDaemon (apex_remote_proxy domain, has network)
      → RemoteModelClient
        → HTTP POST to OmniRoute endpoint
          → http://127.0.0.1:20128/v1/chat/completions
```

### RemoteProxyDaemon (151 lines)

Standalone daemon process listening on localhost:9879.

**Configuration** (via system properties):
- `persist.sys.apex.remote_endpoint` — OmniRoute URL (default: `http://127.0.0.1:20128/v1/chat/completions`)
- `persist.sys.apex.remote_model` — model name (default: `qwen2.5-7b`)

**Protocol** (newline-delimited JSON):
```
Request:  {"prompt":"...","maxTokens":512,"temperature":0.7}
Response: {"ok":true,"text":"..."}  |  {"ok":false,"error":"..."}
```

**Security**:
- Socket restricted to system UID (apexagentd runs as system)
- No prompt content logged or persisted
- Configurable endpoint and model via system properties
- If endpoint not configured, returns error (no fallback to local model — that's the daemon's job)
- Thread pool: 16 max connections

### RemoteModelClient (149 lines)

HTTP client using `java.net.HttpURLConnection` (no external dependencies — this is a system app).

**Request construction** (OpenAI-compatible):
```json
{
  "model": "qwen2.5-7b",
  "messages": [{"role": "user", "content": "..."}],
  "max_tokens": 512,
  "temperature": 0.7,
  "stream": false
}
```

**Timeouts**:
- Connect: 10s
- Read: 30s

**Rate limiting**:
- Max 10 concurrent requests (Semaphore)
- Blocks if at limit, returns error if acquire fails

**Response parsing**:
- Extracts `choices[0].message.content` from OpenAI-format response
- Returns `{"ok":true,"text":"..."}` on success
- Returns `{"ok":false,"error":"..."}` on any failure

**User-Agent**: `APEX-Agent/1.0`

### Consent for Remote Inference

Remote inference uses `ConsentType.REMOTE_INFERENCE`:
- **Timeout**: 30s (shorter than standard 60s — faster auto-deny for data-leaving-device)
- **Warning**: consent card displays "⚠ Data leaves device" warning
- **Per-request**: each remote inference request requires consent (no batch approval)

### OmniRoute Integration

OmniRoute is a local AI model router running on port 20128. It provides an OpenAI-compatible API that routes to multiple model providers. The APEX agent treats it as a standard OpenAI endpoint.

The default model `qwen2.5-7b` is available when OmniRoute is running on the same device (or accessible via Tailscale at `100.87.225.97:20128`). The endpoint is configurable via system property for remote servers.

### SELinux Policy

```
# apex_remote_proxy domain
type apex_remote_proxy, domain;
type apex_remote_proxy_exec, file_type, exec_type;
init_daemon_domain(apex_remote_proxy)

# Network access (the only APEX component with network)
net_domain(apex_remote_proxy)
allow apex_remote_proxy port_9879:tcp_socket { name_bind listen accept };

# Binder to system_server (for consent checks)
binder_call(apex_remote_proxy, system_server)

# No access to sysfs, procfs, or device nodes
neverallow apex_remote_proxy sysfs:file { read write };
neverallow apex_remote_proxy proc_apex:file { read write };
```

## Voice Subsystem

### VoiceManager (133 lines)

On-device speech-to-text and wake-word detection using whisper.cpp.

### Architecture
```
AudioRecord (16kHz, 16-bit, mono)
  → Ring buffer (4 seconds, 128KB)
    → WakeWordDetector (VAD + keyword spotting, 1 A53 core)
      → On wake: start WhisperDecoder
        → WhisperDecoder (whisper.cpp JNI, 2 A73 cores)
          → Transcript → feed to agent as user message
```

### CPU Budget
| Component | CPU | Cores | Latency |
|-----------|-----|-------|---------|
| Wake-word VAD | ~2-3% | 1x A53 | Continuous |
| Whisper STT (tiny.en) | ~15-25% | 2x A73 | 1-3s for short phrase |
| Idle (no audio) | 0% | None | AudioRecord stopped |

### Memory
| Component | Size |
|-----------|------|
| Whisper tiny.en model (ggml) | ~75MB |
| Audio ring buffer (4s @ 16kHz 16-bit) | 128KB |
| Total voice subsystem | ~80MB |

### JNI Bridge (whisper_jni.c, 173 lines)

Native methods:
- `nativeLoadWhisperModel(path)` → loads `ggml-tiny.en.bin`
- `nativeTranscribe(handle, audioData)` → returns transcript text
- `nativeStartWakeWord(ringBufferSize)` → starts VAD loop
- `nativeStopWakeWord()` → stops VAD loop

### Privacy
- All audio processed on-device, never transmitted
- Audio buffer cleared after each transcription
- Wake-word detector runs only when screen on or agent active
- No audio is stored persistently

### Wake-Word Detection

Uses Voice Activity Detection (VAD) + lightweight keyword spotting:
- VAD detects speech segments in the ring buffer
- Keyword spotting checks for the wake word "APEX" in detected speech
- On detection, starts full Whisper transcription
- After transcription, feeds transcript to agent as a user message

### Build

The whisper.cpp library is built via `agent/llm/build-whisper.sh`:
- Downloads whisper.cpp source
- Cross-compiles for aarch64 with `-O3 -march=armv8.2-a`
- Produces `libwhisper_jni.so`
- Model file `ggml-tiny.en.bin` must be downloaded separately (~75MB)

### Model Storage
- Whisper model: `/data/local/tmp/models/ggml-tiny.en.bin`
- LLM models: `/data/local/tmp/models/*.gguf`
