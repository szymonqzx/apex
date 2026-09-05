/*
 * llm_jni.c — JNI bridge for llama.cpp
 *
 * Provides Java Native Interface methods used by ApexAgentDaemon
 * to load models, generate text, and manage memory.
 *
 * Compiled as libllm_jni.so, loaded via System.loadLibrary("llm_jni").
 */

#include <jni.h>
#include <android/log.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>

#define LOG_TAG "llm_jni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* llama.cpp headers — loaded at build time */
#include "llama.h"

/* Handle to a loaded model + context */
typedef struct {
  struct llama_model *model;
  struct llama_context *ctx;
  int n_threads;
  size_t model_size;
} llama_handle_t;

/* Convert Java string to C string */
static const char *jstr_to_cstr(JNIEnv *env, jstring jstr) {
  if (jstr == NULL) return NULL;
  return (*env)->GetStringUTFChars(env, jstr, NULL);
}

/* Release Java string */
static void release_cstr(JNIEnv *env, jstring jstr, const char *cstr) {
  if (jstr != NULL && cstr != NULL) {
    (*env)->ReleaseStringUTFChars(env, jstr, cstr);
  }
}

/*
 * nativeLoadModel(String path, int nThreads) → long handle
 *
 * Loads a GGUF model from the given path. Returns a handle (pointer
 * cast to jlong) or 0 on failure.
 */
JNIEXPORT jlong JNICALL
Java_com_apex_agent_ApexAgentDaemon_nativeLoadModel(
    JNIEnv *env, jobject this, jstring jpath, jint jthreads) {

  const char *path = jstr_to_cstr(env, jpath);
  if (path == NULL) {
    LOGE("nativeLoadModel: path is NULL");
    return 0;
  }

  int n_threads = (int) jthreads;
  if (n_threads < 1) n_threads = 4;

  LOGI("Loading model: %s (threads=%d)", path, n_threads);

  /* Initialize llama.cpp backend */
  llama_backend_init(false);

  /* Load model */
  struct llama_model_params model_params = llama_model_default_params();
  model_params.n_gpu_layers = 0;  /* CPU-only */

  struct llama_model *model = llama_model_load_from_file(path, model_params);
  if (model == NULL) {
    LOGE("Failed to load model: %s", path);
    release_cstr(env, jpath, path);
    return 0;
  }

  /* Create context */
  struct llama_context_params ctx_params = llama_context_default_params();
  ctx_params.n_threads = n_threads;
  ctx_params.n_threads_batch = n_threads;
  ctx_params.n_ctx = 2048;  /* context window */
  ctx_params.n_batch = 512;

  struct llama_context *ctx = llama_new_context_with_model(model, ctx_params);
  if (ctx == NULL) {
    LOGE("Failed to create context");
    llama_model_free(model);
    release_cstr(env, jpath, path);
    return 0;
  }

  /* Allocate handle */
  llama_handle_t *handle = (llama_handle_t *) calloc(1, sizeof(llama_handle_t));
  if (handle == NULL) {
    LOGE("Failed to allocate handle");
    llama_free(ctx);
    llama_model_free(model);
    release_cstr(env, jpath, path);
    return 0;
  }

  handle->model = model;
  handle->ctx = ctx;
  handle->n_threads = n_threads;
  handle->model_size = 0;  /* TODO: get actual model size */

  LOGI("Model loaded successfully (handle=%p)", handle);
  release_cstr(env, jpath, path);
  return (jlong) (intptr_t) handle;
}

/*
 * nativeGenerate(long handle, String prompt, int maxTokens, float temp) → String
 *
 * Generates text from the given prompt. Returns the generated text
 * or an error message.
 */
JNIEXPORT jstring JNICALL
Java_com_apex_agent_ApexAgentDaemon_nativeGenerate(
    JNIEnv *env, jobject this, jlong jhandle,
    jstring jprompt, jint jmax_tokens, jfloat jtemp) {

  llama_handle_t *handle = (llama_handle_t *) (intptr_t) jhandle;
  if (handle == NULL || handle->ctx == NULL) {
    return (*env)->NewStringUTF(env, "[error] Invalid model handle");
  }

  const char *prompt = jstr_to_cstr(env, jprompt);
  if (prompt == NULL) {
    return (*env)->NewStringUTF(env, "[error] Prompt is NULL");
  }

  int max_tokens = (int) jmax_tokens;
  if (max_tokens < 1) max_tokens = 256;
  if (max_tokens > 1024) max_tokens = 1024;

  float temp = (float) jtemp;
  if (temp < 0.0f) temp = 0.7f;
  if (temp > 2.0f) temp = 2.0f;

  /* Tokenize prompt */
  int n_ctx = llama_n_ctx(handle->ctx);
  int n_prompt = llama_tokenize(handle->model,
      (const uint8_t *) prompt, strlen(prompt),
      NULL, 0, true, true);

  if (n_prompt < 0) {
    n_prompt = -n_prompt;  /* actual required size */
  }

  if (n_prompt > n_ctx - 4) {
    n_prompt = n_ctx - 4;  /* truncate to fit context */
  }

  llama_token *tokens = (llama_token *) malloc(n_prompt * sizeof(llama_token));
  if (tokens == NULL) {
    release_cstr(env, jprompt, prompt);
    return (*env)->NewStringUTF(env, "[error] Out of memory");
  }

  int actual = llama_tokenize(handle->model,
      (const uint8_t *) prompt, strlen(prompt),
      tokens, n_prompt, true, true);

  if (actual < 0) {
    LOGE("Tokenization failed");
    free(tokens);
    release_cstr(env, jprompt, prompt);
    return (*env)->NewStringUTF(env, "[error] Tokenization failed");
  }

  n_prompt = actual;

  /* Evaluate prompt */
  int n_batch = llama_n_batch(handle->ctx);
  for (int i = 0; i < n_prompt; i += n_batch) {
    int n_eval = n_prompt - i;
    if (n_eval > n_batch) n_eval = n_batch;
    if (llama_decode(handle->ctx,
        llama_batch_get_one(tokens + i, n_eval, i, 0)) != 0) {
      LOGE("Failed to evaluate prompt at batch %d", i);
      free(tokens);
      release_cstr(env, jprompt, prompt);
      return (*env)->NewStringUTF(env, "[error] Evaluation failed");
    }
  }

  free(tokens);
  release_cstr(env, jprompt, prompt);

  /* Generate tokens */
  char *output = (char *) malloc(max_tokens * 8 + 1);  /* max 8 bytes per UTF-8 char */
  if (output == NULL) {
    return (*env)->NewStringUTF(env, "[error] Out of memory");
  }
  output[0] = '\0';
  int out_len = 0;

  llama_token last_token = llama_token_eos(handle->model);

  for (int i = 0; i < max_tokens; i++) {
    float *logits = llama_get_logits_ith(handle->ctx, -1);

    /* Apply temperature */
    llama_token_data *candidates = (llama_token_data *)
        malloc(llama_n_vocab(handle->model) * sizeof(llama_token_data));
    if (candidates == NULL) break;

    for (int v = 0; v < llama_n_vocab(handle->model); v++) {
      candidates[v].id = v;
      candidates[v].logit = logits[v];
      candidates[v].p = 0.0f;
    }

    llama_token_data_array array = {
      .data = candidates,
      .size = llama_n_vocab(handle->model),
      .selected = -1
    };

    /* Simple temperature sampling */
    if (temp > 0.0f) {
      /* Apply temperature */
      for (int v = 0; v < array.size; v++) {
        candidates[v].logit /= temp;
      }
      llama_sample_softmax(NULL, &array);
      /* Top-k = 40 */
      if (array.size > 40) array.size = 40;
      llama_sample_top_p(NULL, &array, 0.9f, 1);
      last_token = llama_sample_token(NULL, &array);
    } else {
      last_token = llama_sample_token_greedy(NULL, &array);
    }

    free(candidates);

    if (last_token == llama_token_eos(handle->model)) {
      break;
    }

    /* Convert token to text */
    char buf[16];
    int len = llama_token_to_piece(handle->model, last_token, buf, sizeof(buf));
    if (len > 0) {
      if (out_len + len < max_tokens * 8) {
        memcpy(output + out_len, buf, len);
        out_len += len;
        output[out_len] = '\0';
      }
    }

    /* Evaluate the new token */
    if (llama_decode(handle->ctx,
        llama_batch_get_one(&last_token, 1, n_prompt + i, 0)) != 0) {
      LOGE("Failed to evaluate generated token %d", i);
      break;
    }
  }

  jstring result = (*env)->NewStringUTF(env, output);
  free(output);
  return result;
}

/*
 * nativeUnloadModel(long handle)
 *
 * Unloads the model and frees all resources.
 */
JNIEXPORT void JNICALL
Java_com_apex_agent_ApexAgentDaemon_nativeUnloadModel(
    JNIEnv *env, jobject this, jlong jhandle) {

  llama_handle_t *handle = (llama_handle_t *) (intptr_t) jhandle;
  if (handle == NULL) return;

  LOGI("Unloading model (handle=%p)", handle);

  if (handle->ctx != NULL) {
    llama_free(handle->ctx);
    handle->ctx = NULL;
  }
  if (handle->model != NULL) {
    llama_model_free(handle->model);
    handle->model = NULL;
  }

  free(handle);
}

/*
 * nativeGetMemoryUsage(long handle) → int
 *
 * Returns the approximate memory usage of the loaded model in MB.
 */
JNIEXPORT jint JNICALL
Java_com_apex_agent_ApexAgentDaemon_nativeGetMemoryUsage(
    JNIEnv *env, jobject this, jlong jhandle) {

  llama_handle_t *handle = (llama_handle_t *) (intptr_t) jhandle;
  if (handle == NULL) return 0;

  /* Approximate: model size + context memory */
  int ctx_mem = llama_n_ctx(handle->ctx) * 128 / 1024;  /* rough estimate */
  return (jint) (handle->model_size / (1024 * 1024) + ctx_mem);
}

/*
 * nativeSetThreadCount(long handle, int nThreads)
 *
 * Sets the number of threads for inference.
 */
JNIEXPORT void JNICALL
Java_com_apex_agent_ApexAgentDaemon_nativeSetThreadCount(
    JNIEnv *env, jobject this, jlong jhandle, jint jthreads) {

  llama_handle_t *handle = (llama_handle_t *) (intptr_t) jhandle;
  if (handle == NULL) return;

  handle->n_threads = (int) jthreads;
  /* llama.cpp uses n_threads from context params; would need context
   * recreation to change at runtime. For now, stored for next load. */
  LOGI("Thread count set to %d (effective on next model load)", handle->n_threads);
}
