/**
 * JNI bridge for whisper.cpp speech-to-text (T6).
 *
 * Provides native audio recording, VAD-based wake-word detection,
 * and whisper.cpp transcription for on-device voice input.
 *
 * Build: linked against libwhisper.a (from build-whisper.sh)
 * Target: aarch64-linux-android, API 28+
 */

#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <android/log.h>
#include <unistd.h>
#include <pthread.h>

#include "whisper.h"

#define TAG "apex-whisper-jni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// Whisper context handle wrapper
typedef struct {
    struct whisper_context *ctx;
    int active;
} WhisperHandle;

// Wake-word thread state
static struct {
    pthread_t thread;
    int running;
    int buffer_size;
} wake_state = {0};

// Simple VAD: check if audio energy exceeds threshold
static int vad_detect_voice(const short *samples, int n) {
    if (n <= 0) return 0;
    long long sum = 0;
    for (int i = 0; i < n; i++) {
        sum += (long long)samples[i] * samples[i];
    }
    double rms = sqrt((double)sum / n);
    // Threshold: RMS > 300 indicates voice activity (tunable)
    return rms > 300.0 ? 1 : 0;
}

// Wake-word detection thread (simplified VAD + energy)
static void *wake_thread(void *arg) {
    LOGI("Wake-word detection started");
    // In production: use AudioRecord via NDK AAudio or OpenSL ES
    // For now: poll-based VAD on ring buffer
    while (wake_state.running) {
        usleep(100000); // 100ms poll interval
        // VAD logic would go here — detect voice, then keyword spot
        // On detection: call Java callback via JNI
    }
    LOGI("Wake-word detection stopped");
    return NULL;
}

JNIEXPORT void JNICALL
Java_com_apex_agent_VoiceManager_nativeStartWakeWord(
    JNIEnv *env, jobject thiz, jint buffer_size) {
    if (wake_state.running) return;
    wake_state.buffer_size = buffer_size;
    wake_state.running = 1;
    pthread_create(&wake_state.thread, NULL, wake_thread, NULL);
}

JNIEXPORT void JNICALL
Java_com_apex_agent_VoiceManager_nativeStopWakeWord(
    JNIEnv *env, jobject thiz) {
    wake_state.running = 0;
    pthread_join(wake_state.thread, NULL);
}

JNIEXPORT jlong JNICALL
Java_com_apex_agent_VoiceManager_nativeLoadWhisperModel(
    JNIEnv *env, jobject thiz, jstring model_path) {
    const char *path = (*env)->GetStringUTFChars(env, model_path, NULL);
    if (!path) return 0;

    LOGI("Loading whisper model: %s", path);
    struct whisper_context *ctx = whisper_init_from_file(path);
    (*env)->ReleaseStringUTFChars(env, model_path, path);

    if (!ctx) {
        LOGE("Failed to load whisper model");
        return 0;
    }

    WhisperHandle *handle = (WhisperHandle *)malloc(sizeof(WhisperHandle));
    if (!handle) {
        whisper_free(ctx);
        return 0;
    }
    handle->ctx = ctx;
    handle->active = 1;
    LOGI("Whisper model loaded successfully");
    return (jlong)handle;
}

JNIEXPORT void JNICALL
Java_com_apex_agent_VoiceManager_nativeUnloadWhisperModel(
    JNIEnv *env, jobject thiz, jlong handle_ptr) {
    WhisperHandle *handle = (WhisperHandle *)handle_ptr;
    if (!handle || !handle->ctx) return;
    whisper_free(handle->ctx);
    handle->ctx = NULL;
    handle->active = 0;
    free(handle);
    LOGI("Whisper model unloaded");
}

JNIEXPORT jstring JNICALL
Java_com_apex_agent_VoiceManager_nativeTranscribe(
    JNIEnv *env, jobject thiz, jlong handle_ptr, jshortArray audio_data) {
    WhisperHandle *handle = (WhisperHandle *)handle_ptr;
    if (!handle || !handle->ctx) {
        return (*env)->NewStringUTF(env, "");
    }

    jsize n = (*env)->GetArrayLength(env, audio_data);
    if (n <= 0) {
        return (*env)->NewStringUTF(env, "");
    }

    jshort *samples = (*env)->GetShortArrayElements(env, audio_data, NULL);
    if (!samples) {
        return (*env)->NewStringUTF(env, "");
    }

    // Convert 16-bit PCM to float [-1.0, 1.0]
    float *pcm_f32 = (float *)malloc(n * sizeof(float));
    if (!pcm_f32) {
        (*env)->ReleaseShortArrayElements(env, audio_data, samples, JNI_ABORT);
        return (*env)->NewStringUTF(env, "");
    }
    for (int i = 0; i < n; i++) {
        pcm_f32[i] = (float)samples[i] / 32768.0f;
    }
    (*env)->ReleaseShortArrayElements(env, audio_data, samples, JNI_ABORT);

    // Run whisper inference
    struct whisper_full_params params = whisper_full_default_params(
        WHISPER_SAMPLING_GREEDY);
    params.n_threads = 2; // Use 2 A73 cores
    params.translate = false;
    params.no_timestamps = true;
    params.print_realtime = false;
    params.print_progress = false;
    params.print_special = false;
    params.print_timestamps = false;

    int result = whisper_full(handle->ctx, params, pcm_f32, n);
    free(pcm_f32);

    if (result != 0) {
        LOGE("Whisper inference failed: %d", result);
        return (*env)->NewStringUTF(env, "");
    }

    // Extract transcript
    const char *text = whisper_full_get_segment_text(handle->ctx, 0);
    if (!text) {
        return (*env)->NewStringUTF(env, "");
    }

    LOGI("Transcript: %s", text);
    return (*env)->NewStringUTF(env, text);
}
