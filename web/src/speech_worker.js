// Speech recognition worker: whisper.cpp (WebAssembly) with a bundled model.
// Nothing leaves the device. One job per worker; the page terminates it to cancel.
import createSpeech from './hbr_speech.js';

// Bundled in the offline app; a hosted copy may leave it out (the page then
// lets the person choose the file and passes it in).
const MODEL_PARTS = ['models/ggml-tiny-q5_1.bin'];
const post = (m) => self.postMessage(m);

async function fetchModel() {
  const res = await Promise.all(MODEL_PARTS.map((p) => fetch(new URL(p, self.location.href))));
  if (res.some((r) => !r.ok)) throw Object.assign(new Error('The speech model is not included in this copy of the app.'), { code: 'nomodel' });
  const sizes = res.map((r) => +r.headers.get('content-length') || 0);
  const known = sizes.every((n) => n > 0);
  const total = sizes.reduce((a, b) => a + b, 0);
  const chunks = [];
  let got = 0, last = -1;
  for (const r of res) {
    const reader = r.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      got += value.length;
      const pct = known ? Math.min(100, Math.floor((got / total) * 100)) : 0;
      if (pct !== last) post({ type: 'progress', stage: 'model', pct: (last = pct) });
    }
  }
  const buf = new Uint8Array(got);
  let o = 0;
  for (const c of chunks) { buf.set(c, o); o += c.length; }
  return buf;
}

self.onmessage = async ({ data }) => {
  try {
    const { pcm, language, model: given } = data;
    post({ type: 'progress', stage: 'model', pct: 0 });
    const [M, model] = await Promise.all([
      createSpeech({ locateFile: (p) => new URL(p, import.meta.url).href, print: () => {}, printErr: () => {} }),
      given ? new Uint8Array(given) : fetchModel(),
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
    post({ type: 'error', message: e.message || String(e), code: e.code });
  }
};
