package com.apex.agent;

/**
 * Voice subsystem for on-device STT and wake-word detection (T6).
 *
 * Architecture:
 *   AudioRecord (16kHz, 16-bit, mono) → ring buffer
 *     → WakeWordDetector (VAD + keyword spotting)
 *       → on wake: start WhisperDecoder
 *         → WhisperDecoder (whisper.cpp JNI) → transcript
 *           → feed transcript to agent as user message
 *
 * CPU budget on A73 (4x 2.0GHz + 4x 1.7GHz A53):
 *   - Wake-word VAD: ~2-3% CPU (single A53 core, lightweight)
 *   - Whisper STT (tiny.en): ~15-25% CPU (2x A73 cores, 1-3s for short phrase)
 *   - Idle (no audio): 0% (AudioRecord stopped)
 *
 * Memory:
 *   - Whisper tiny.en model: ~75MB (ggml)
 *   - Audio ring buffer: 128KB (4s @ 16kHz 16-bit)
 *   - Total voice subsystem: ~80MB
 *
 * Privacy:
 *   - All audio processed on-device, never transmitted
 *   - Audio buffer cleared after each transcription
 *   - Wake-word detector runs only when screen on or agent active
 */
public final class VoiceManager {

    private static final int SAMPLE_RATE = 16000;
    private static final int CHANNELS = 1;
    private static final int RING_BUFFER_SECONDS = 4;
    private static final int RING_BUFFER_SIZE = SAMPLE_RATE * CHANNELS * 2 * RING_BUFFER_SECONDS;

    private volatile boolean wakeWordActive = false;
    private volatile boolean sttActive = false;
    private long whisperHandle = 0; // JNI handle to whisper_context

    // Wake-word callback
    public interface WakeWordCallback {
        void onWakeWordDetected();
    }

    // STT callback
    public interface SttCallback {
        void onTranscriptReady(String transcript);
        void onError(String error);
    }

    /**
     * Start wake-word detection. Uses VAD + lightweight keyword spotting.
     * Runs on a single A53 core to minimize power and thermal impact.
     */
    public synchronized void startWakeWordDetection(WakeWordCallback callback) {
        if (wakeWordActive) return;
        wakeWordActive = true;
        // JNI call to start AudioRecord + VAD loop
        nativeStartWakeWord(RING_BUFFER_SIZE);
    }

    /**
     * Stop wake-word detection.
     */
    public synchronized void stopWakeWordDetection() {
        wakeWordActive = false;
        nativeStopWakeWord();
    }

    /**
     * Start speech-to-text transcription using whisper.cpp.
     * Loads whisper tiny.en model if not already loaded.
     *
     * @param audioData  Raw 16kHz 16-bit mono PCM audio
     * @param callback   Callback for transcript or error
     */
    public synchronized void transcribe(short[] audioData, SttCallback callback) {
        if (sttActive) {
            callback.onError("STT already active");
            return;
        }
        sttActive = true;
        // Load model if needed
        if (whisperHandle == 0) {
            whisperHandle = nativeLoadWhisperModel(
                "/data/local/tmp/models/ggml-tiny.en.bin"
            );
            if (whisperHandle == 0) {
                sttActive = false;
                callback.onError("Failed to load whisper model");
                return;
            }
        }
        // Run transcription (blocking, called from worker thread)
        String transcript = nativeTranscribe(whisperHandle, audioData);
        sttActive = false;
        if (transcript != null && !transcript.isEmpty()) {
            callback.onTranscriptReady(transcript.trim());
        } else {
            callback.onError("Empty transcript");
        }
    }

    /**
     * Unload whisper model to free memory.
     */
    public synchronized void unloadModel() {
        if (whisperHandle != 0) {
            nativeUnloadWhisperModel(whisperHandle);
            whisperHandle = 0;
        }
    }

    /**
     * Check if wake-word detection is active.
     */
    public boolean isWakeWordActive() {
        return wakeWordActive;
    }

    /**
     * Check if STT transcription is in progress.
     */
    public boolean isSttActive() {
        return sttActive;
    }

    // Native methods (implemented in libwhisper_jni.so)
    private native void nativeStartWakeWord(int bufferSize);
    private native void nativeStopWakeWord();
    private native long nativeLoadWhisperModel(String modelPath);
    private native void nativeUnloadWhisperModel(long handle);
    private native String nativeTranscribe(long handle, short[] audioData);
}
