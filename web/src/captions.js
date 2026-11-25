// Captions for the web app: grouping words into captions, transcribing in a
// worker (whisper.cpp in WebAssembly, fully offline) and burning captions
// into frames with the same look as the phone app.

export const PRESETS = ['pop', 'box', 'clean', 'karaoke'];
export const HIGHLIGHTS = [0xffffd60a, 0xff2dd4bf, 0xffff4d8d, 0xff7cfc00, 0xffff8a00, 0xffffffff];
export const LANGUAGES = [
  ['en', 'English'], ['auto', 'Detect automatically'], ['fr', 'French'], ['es', 'Spanish'],
  ['pt', 'Portuguese'], ['de', 'German'], ['ar', 'Arabic'], ['hi', 'Hindi'], ['sw', 'Swahili'],
  ['yo', 'Yoruba'], ['ha', 'Hausa'], ['zh', 'Chinese'],
];

/** Words -> captions of a few words each (same rules as the phone app). */
export function groupCues(words, maxWords = 5, maxChars = 28) {
  const cues = [];
  let cur = [], chars = 0;
  const push = () => { if (cur.length) cues.push({ words: cur }); cur = []; chars = 0; };
  for (const w of words) {
    if (!w.w || !w.w.trim()) continue;
    const pause = cur.length && w.t0 - cur[cur.length - 1].t1 > 600;
    if (cur.length && (pause || cur.length >= maxWords || chars + w.w.length + 1 > maxChars)) push();
    cur.push({ ...w });
    chars += w.w.length + 1;
    if (/[.!?]$/.test(w.w)) push();
  }
  push();
  for (let i = 0; i + 1 < cues.length; i++) {
    const a = cues[i].words, gap = cues[i + 1].words[0].t0 - a[a.length - 1].t1;
    if (gap > 0 && gap < 400) a[a.length - 1].t1 = cues[i + 1].words[0].t0;
  }
  return cues.map((c) => ({ t0: c.words[0].t0, t1: c.words[c.words.length - 1].t1, words: c.words }));
}

/** Replaces a caption's text, spreading the new words over its time. */
export function editCue(cue, text) {
  const parts = text.trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return null;
  if (parts.length === cue.words.length) return { ...cue, words: cue.words.map((w, i) => ({ ...w, w: parts[i] })) };
  const span = Math.max(1, cue.t1 - cue.t0), step = span / parts.length;
  return {
    ...cue,
    words: parts.map((p, i) => ({ w: p, t0: Math.round(cue.t0 + i * step), t1: Math.round(cue.t0 + (i + 1) * step) })),
  };
}

// ---------------------------------------------------------------- speech

/** 16 kHz mono float samples of the video's sound. */
async function speechPcm(file) {
  const data = await file.arrayBuffer();
  const probe = new OfflineAudioContext(1, 16000, 16000);
  const decoded = await probe.decodeAudioData(data);
  const n = Math.ceil(decoded.duration * 16000);
  const ctx = new OfflineAudioContext(1, Math.max(1, n), 16000);
  const src = ctx.createBufferSource();
  src.buffer = decoded;
  src.connect(ctx.destination);
  src.start();
  const out = await ctx.startRendering();
  return out.getChannelData(0);
}

/**
 * Words spoken in the video: [{w, t0, t1}] in ms. Runs fully on this device.
 * onProgress(stage, pct) with stage 'audio' | 'model' | 'listen'.
 */
export async function transcribe(file, language, { onProgress, signal } = {}) {
  onProgress?.('audio', 0);
  let pcm;
  try { pcm = await speechPcm(file); } catch { throw new Error('This video has no sound that can be read.'); }
  if (signal?.aborted) throw new DOMException('cancelled', 'AbortError');
  const worker = new Worker(new URL('./speech_worker.js', import.meta.url), { type: 'module' });
  try {
    return await new Promise((resolve, reject) => {
      const stop = () => reject(new DOMException('cancelled', 'AbortError'));
      signal?.addEventListener('abort', stop, { once: true });
      worker.onerror = (e) => reject(new Error(e.message || 'Speech recognition could not start'));
      worker.onmessage = ({ data }) => {
        if (data.type === 'progress') onProgress?.(data.stage, data.pct);
        else if (data.type === 'done') resolve(data.words);
        else if (data.type === 'error') reject(new Error(data.message));
      };
      worker.postMessage({ pcm, language }, [pcm.buffer]);
    });
  } finally {
    worker.terminate(); // also how cancel stops the work
  }
}

// ---------------------------------------------------------------- drawing

const argbCss = (c, a) => `rgba(${(c >> 16) & 255},${(c >> 8) & 255},${c & 255},${a ?? (((c >>> 24) & 255) / 255)})`;

/**
 * Burns captions into frames. dispW x dispH is the upright output size;
 * rotation is the clockwise display rotation of the stored frames.
 */
export class CaptionPainter {
  constructor(captions, dispW, dispH, rotation = 0) {
    this.cues = (captions?.cues || []).filter((c) => c.words?.length).sort((a, b) => a.t0 - b.t0);
    this.style = { preset: 'pop', position: 'bottom', size: 1, textColor: 0xffffffff, highlightColor: 0xffffd60a, uppercase: false, ...(captions?.style || {}) };
    this.dispW = dispW;
    this.dispH = dispH;
    this.rot = rotation;
    this.cache = new Map();
    this.cursor = 0;
    this.font = Math.max(12, Math.min(dispW, dispH) * 0.062 * Math.min(2, Math.max(0.5, this.style.size)));
    this.ptr = 0;
    this.cap = 0;
  }

  get empty() { return !this.cues.length; }

  cueAt(t) {
    const c = this.cues;
    if (!c.length) return -1;
    if (this.cursor >= c.length || c[this.cursor].t0 > t) this.cursor = 0;
    while (this.cursor < c.length && c[this.cursor].t1 <= t) this.cursor++;
    return this.cursor < c.length && c[this.cursor].t0 <= t ? this.cursor : -1;
  }

  /** Draws the caption for time tMs into the I420 buffer at ptr (stored orientation, w x h). */
  draw(M, ptr, w, h, tMs, matrix, full) {
    const i = this.cueAt(tMs);
    if (i < 0) return;
    const cue = this.cues[i];
    let active = -1;
    if (this.style.preset !== 'clean') {
      for (let k = 0; k < cue.words.length; k++) if (cue.words[k].t0 <= tMs) active = k;
      active = Math.max(0, active);
    }
    const key = i * 1000 + active + 1;
    let s = this.cache.get(key);
    if (!s) {
      s = this.render(cue, active);
      this.cache.set(key, s);
      if (this.cache.size > 12) this.cache.delete(this.cache.keys().next().value);
    }
    const n = s.data.length;
    if (n > this.cap) {
      if (this.ptr) M._hbrw_free(this.ptr);
      this.ptr = M._hbrw_alloc(n);
      this.cap = n;
    }
    M.HEAPU8.set(s.data, this.ptr);
    M._hbrw_overlay_i420(ptr, w, h, this.ptr, s.w, s.h, s.x, s.y, matrix, full ? 1 : 0);
  }

  free(M) {
    if (this.ptr) M._hbrw_free(this.ptr);
    this.ptr = 0;
    this.cap = 0;
  }

  /** Lays the words out in centred lines no wider than maxW. */
  lines(ctx, words, maxW) {
    const space = ctx.measureText(' ').width;
    const out = [];
    let line = [], lw = 0;
    for (let k = 0; k < words.length; k++) {
      const ww = ctx.measureText(words[k]).width;
      if (line.length && lw + space + ww > maxW) { out.push({ items: line, w: lw }); line = []; lw = 0; }
      line.push({ k, text: words[k], w: ww });
      lw += (line.length > 1 ? space : 0) + ww;
    }
    if (line.length) out.push({ items: line, w: lw });
    return { lines: out, space };
  }

  render(cue, active) {
    const st = this.style, f = this.font;
    const words = cue.words.map((x) => (st.uppercase ? x.w.toUpperCase() : x.w));
    const weight = st.preset === 'clean' ? '600' : '900';
    const fontCss = `${weight} ${f}px system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif`;
    const maxW = this.dispW * 0.86;
    const meas = new OffscreenCanvas(8, 8).getContext('2d');
    meas.font = fontCss;
    const { lines, space } = this.lines(meas, words, maxW);
    const lineH = f * 1.18;
    const tw = Math.max(...lines.map((l) => l.w));
    const pad = Math.round(f * 0.45);
    const w = Math.max(2, Math.ceil(tw + 2 * pad) & ~1);
    const h = Math.max(2, Math.ceil(lines.length * lineH + 2 * pad) & ~1);

    const up = new OffscreenCanvas(w, h);
    const c = up.getContext('2d');
    c.font = fontCss;
    c.textBaseline = 'middle';
    c.lineJoin = 'round';
    if (st.preset === 'box') {
      c.fillStyle = 'rgba(0,0,0,0.7)';
      c.beginPath();
      c.roundRect(0, 0, w, h, f * 0.35);
      c.fill();
    }
    const colorOf = (k) => {
      if (st.preset === 'karaoke') return k <= active ? argbCss(st.highlightColor) : argbCss(st.textColor, 0.6);
      if (st.preset !== 'clean' && k === active) return argbCss(st.highlightColor);
      return argbCss(st.textColor);
    };
    const each = (fn) => lines.forEach((l, li) => {
      let x = (w - l.w) / 2;
      const y = pad + lineH * (li + 0.5);
      for (const it of l.items) { fn(it, x, y); x += it.w + space; }
    });
    if (st.preset === 'pop' || st.preset === 'karaoke') {
      c.strokeStyle = '#000';
      c.lineWidth = f * 0.16;
      each((it, x, y) => c.strokeText(it.text, x, y));
    }
    if (st.preset === 'clean') {
      c.shadowColor = 'rgba(0,0,0,0.8)';
      c.shadowBlur = f * 0.18;
      c.shadowOffsetY = f * 0.06;
    }
    each((it, x, y) => { c.fillStyle = colorOf(it.k); c.fillText(it.text, x, y); });

    // place on the upright frame
    const cy = st.position === 'top' ? 0.16 : st.position === 'middle' ? 0.5 : 0.8;
    const xd = ((this.dispW - w) / 2) & ~1;
    const yd = Math.min(Math.max(0, Math.round(this.dispH * cy - h / 2)), Math.max(0, this.dispH - h)) & ~1;

    // into stored orientation
    const rot = this.rot;
    const sideways = rot % 180 !== 0;
    const ow = sideways ? h : w, oh = sideways ? w : h;
    let src = up;
    if (rot) {
      src = new OffscreenCanvas(ow, oh);
      const r = src.getContext('2d');
      r.translate(ow / 2, oh / 2);
      r.rotate((-rot * Math.PI) / 180);
      r.drawImage(up, -w / 2, -h / 2);
    }
    const sw = sideways ? this.dispH : this.dispW, sh = sideways ? this.dispW : this.dispH;
    let x = xd, y = yd;
    if (rot === 90) { x = yd; y = sh - (xd + w); }
    else if (rot === 180) { x = sw - (xd + w); y = sh - (yd + h); }
    else if (rot === 270) { x = sw - (yd + h); y = xd; }
    const data = src.getContext('2d').getImageData(0, 0, ow, oh).data;
    return { data, w: ow, h: oh, x, y };
  }
}
