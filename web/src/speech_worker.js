// Speech recognition worker: whisper.cpp (WebAssembly) with a bundled model.
// Nothing leaves the device. One job per worker; the page terminates it to cancel.
import createSpeech from './hbr_speech.js';

const MODEL = 'models/ggml-tiny-q5_1.bin';
const post = (m) => self.postMessage(m);

async function fetchModel() {
  const res = await fetch(new URL(MODEL, self.location.href));
  if (!res.ok) throw new Error('The speech model is missing from this app.');
  const total = +res.headers.get('content-length') || 0;
  if (!res.body || !total) return new Uint8Array(await res.arrayBuffer());
  const buf = new Uint8Array(total);
  const reader = res.body.getReader();
  let got = 0, last = -1;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf.set(value, got);
    got += value.length;
    const pct = Math.floor((got / total) * 100);
    if (pct !== last) post({ type: 'progress', stage: 'model', pct: (last = pct) });
  }
  return got === total ? buf : buf.subarray(0, got);
}

self.onmessage = async ({ data }) => {
  try {
    const { pcm, language } = data;
    post({ type: 'progress', stage: 'model', pct: 0 });
    const [M, model] = await Promise.all([
      createSpeech({ locateFile: (p) => new URL(p, import.meta.url).href, print: () => {}, printErr: () => {} }),
      fetchModel(),
    ]);
    const mp = M._hbrw_salloc(model.length);
    M.HEAPU8.set(model, mp);
    const s = M._hbrw_speech_load(mp, model.length);
    M._hbrw_sfree(mp);
    if (!s) throw new Error('The speech model could not be loaded.');

    M.onSpeechProgress = (pct) => { post({ type: 'progress', stage: 'listen', pct }); return 0; };
    post({ type: 'progress', stage: 'listen', pct: 0 });
    const pp = M._hbrw_salloc(pcm.length * 4);
    M.HEAPF32.set(pcm, pp >> 2);
    const lang = language || 'en';
    const lp = M._hbrw_salloc(M.lengthBytesUTF8(lang) + 1);
    M.stringToUTF8(lang, lp, M.lengthBytesUTF8(lang) + 1);
    const jp = M._hbrw_speech_transcribe(s, pp, pcm.length, lp);
    M._hbrw_sfree(pp);
    M._hbrw_sfree(lp);
    if (!jp) throw new Error('No speech could be recognised.');
    const words = JSON.parse(M.UTF8ToString(jp));
    M._hbrw_speech_free(jp);
    post({ type: 'done', words });
  } catch (e) {
    post({ type: 'error', message: e.message || String(e) });
  }
};
