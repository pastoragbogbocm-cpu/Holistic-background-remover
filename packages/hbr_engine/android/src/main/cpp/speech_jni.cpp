// JNI for on-device speech recognition (captions).
#include <jni.h>

#include "hbr/hbr_speech.h"

namespace {
struct Cb {
  JNIEnv* env;
  jobject listener;
  jmethodID method;
};
}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_holistic_hbr_1engine_Transcriber_nativeLoad(JNIEnv* env, jclass, jstring path) {
  const char* p = env->GetStringUTFChars(path, nullptr);
  hbr_speech* s = hbr_speech_load_file(p);
  env->ReleaseStringUTFChars(path, p);
  return reinterpret_cast<jlong>(s);
}

JNIEXPORT void JNICALL
Java_com_holistic_hbr_1engine_Transcriber_nativeDestroy(JNIEnv*, jclass, jlong h) {
  hbr_speech_destroy(reinterpret_cast<hbr_speech*>(h));
}

// listener: object with `boolean onProgress(int percent)` (true = cancel)
JNIEXPORT jstring JNICALL
Java_com_holistic_hbr_1engine_Transcriber_nativeTranscribe(JNIEnv* env, jclass, jlong h,
                                                          jfloatArray pcm, jstring lang,
                                                          jint threads, jobject listener) {
  jsize n = env->GetArrayLength(pcm);
  jfloat* data = env->GetFloatArrayElements(pcm, nullptr);
  const char* l = env->GetStringUTFChars(lang, nullptr);
  Cb cb{env, listener, nullptr};
  if (listener) {
    jclass k = env->GetObjectClass(listener);
    cb.method = env->GetMethodID(k, "onProgress", "(I)Z");
  }
  char* json = hbr_speech_transcribe(
      reinterpret_cast<hbr_speech*>(h), data, n, l, threads,
      listener && cb.method ? [](int pct, void* u) -> int {
        auto* c = static_cast<Cb*>(u);
        return c->env->CallBooleanMethod(c->listener, c->method, pct) ? 1 : 0;
      } : nullptr,
      &cb);
  env->ReleaseStringUTFChars(lang, l);
  env->ReleaseFloatArrayElements(pcm, data, JNI_ABORT);
  if (!json) return nullptr;
  jstring r = env->NewStringUTF(json);
  hbr_speech_free(json);
  return r;
}
}
