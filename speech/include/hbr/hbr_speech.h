/* On-device speech-to-text for captions (whisper.cpp). Shared by Android
 * (JNI), the web (WASM) and desktop tests. */
#ifndef HBR_SPEECH_H
#define HBR_SPEECH_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hbr_speech hbr_speech;

/* Loads a ggml Whisper model from a file or from memory. NULL on failure. */
hbr_speech* hbr_speech_load_file(const char* path);
hbr_speech* hbr_speech_load_buffer(const void* data, unsigned long size);
void hbr_speech_destroy(hbr_speech* s);

/* progress: 0..100. Return non-zero from it to cancel. */
typedef int (*hbr_speech_progress)(int percent, void* user);

/* Transcribes 16 kHz mono float PCM. language: "en", "fr", ... or "auto".
 * Returns a malloc'd JSON array of words with times in milliseconds:
 *   [{"w":"Hello","t0":120,"t1":480}, ...]
 * or NULL on failure/cancel. Free with hbr_speech_free(). */
char* hbr_speech_transcribe(hbr_speech* s, const float* pcm, int samples,
                            const char* language, int threads,
                            hbr_speech_progress progress, void* user);
void hbr_speech_free(char* p);

#ifdef __cplusplus
}
#endif
#endif
