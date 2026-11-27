// In-browser, offline video background replacement at source quality.
//
// demux (mp4box) -> WebCodecs VideoDecoder (full resolution) -> MediaPipe
// person segmentation on a small upright copy -> shared C++ engine in WASM
// (temporal smoothing, full-res edge refinement, edge colour clean-up,
// Y'CbCr compositing) -> WebCodecs VideoEncoder (same codec family, size,
// timestamps, colour, bitrate >= source) -> mp4 mux with the ORIGINAL audio
// samples copied untouched.
import { createFile, DataStream, Endianness, MP4BoxBuffer } from 'mp4box';
import { Muxer, ArrayBufferTarget } from 'mp4-muxer';
import { FilesetResolver, ImageSegmenter } from '@mediapipe/tasks-vision';
import { Engine, loadCore, matrixOf, i420Size } from './engine.js';
import { CaptionPainter } from './captions.js';

const models = {};
async function modelBuffer(landscape) {
  const key = landscape ? 'LANDSCAPE' : 'SQUARE';
  if (!models[key]) {
    const m = await import('./models.js');
    models[key] = Uint8Array.from(atob(m[key]), (c) => c.charCodeAt(0));
  }
  return models[key];
}

const BASE = new URL('.', import.meta.url).href;
let filesetPromise;
const segmenters = new Map();

async function segmenter(mode, landscape) {
  const key = `${mode}-${landscape}`;
  if (segmenters.has(key)) return segmenters.get(key);
  filesetPromise ??= FilesetResolver.forVisionTasks(BASE + 'vendor');
  const fileset = await filesetPromise;
  const model = await modelBuffer(landscape);
  let seg;
  // CPU first: some phone GPUs return empty masks in the browser (the person then vanishes).
  for (const delegate of ['CPU', 'GPU']) {
    try {
      seg = await ImageSegmenter.createFromOptions(fileset, {
        baseOptions: { modelAssetBuffer: model, delegate },
        runningMode: mode,
        outputConfidenceMasks: true,
        outputCategoryMask: false,
      });
      break;
    } catch (e) {
      console.warn(`segmenter ${delegate} failed`, e);
    }
  }
  if (!seg) throw new Error('Person segmentation could not start in this browser');
  segmenters.set(key, seg);
  return seg;
}

function personMask(result) {
  const masks = result.confidenceMasks;
  if (!masks?.length) throw new Error('no mask');
  const m = masks[masks.length - 1]; // person is the last mask
  const out = { data: m.getAsFloat32Array().slice(), w: m.width, h: m.height };
  result.close?.();
  return out;
}

const tick = () => new Promise((r) => setTimeout(r, 0));

// ---------------------------------------------------------------- demux

export async function demux(file) {
  const buf = await file.arrayBuffer();
  const mp4 = createFile();
  const samples = {};
  const info = await new Promise((resolve, reject) => {
    mp4.onError = (e) => reject(new Error('Not a readable MP4/MOV file: ' + e));
    mp4.onSamples = (id, _u, s) => samples[id].push(...s);
    mp4.onReady = (info) => {
      // ask for every sample of the first video and audio track, then let
      // mp4box hand them over while it parses the buffer
      for (const t of [info.videoTracks[0], info.audioTracks[0]]) {
        if (!t) continue;
        samples[t.id] = [];
        mp4.setExtractionOptions(t.id, null, { nbSamples: t.nb_samples });
      }
      mp4.start();
      resolve(info);
    };
    mp4.appendBuffer(MP4BoxBuffer.fromArrayBuffer(buf, 0), true);
    mp4.flush();
    setTimeout(() => reject(new Error('Not a readable MP4/MOV file')), 8000);
  });
  const vt = info.videoTracks[0];
  if (!vt) throw new Error('No video track');
  const at = info.audioTracks[0];
  // samples may arrive after onReady (moov before mdat): wait until complete
  for (let i = 0; i < 200 && samples[vt.id].length < vt.nb_samples; i++) {
    mp4.flush();
    await tick();
  }
  if (!samples[vt.id].length) throw new Error('No video frames found in this file');
  const m = vt.matrix; // 16.16 fixed: [a b u c d v x y w]
  const rot = ((Math.round((Math.atan2(m[1], m[0]) * 180) / Math.PI) % 360) + 360) % 360;
  const durS = vt.duration / vt.timescale || info.duration / info.timescale;
  const vs = samples[vt.id];
  const meta = {
    width: vt.video?.width ?? vt.track_width,
    height: vt.video?.height ?? vt.track_height,
    rotation: rot,
    codec: vt.codec,
    durationS: durS,
    fps: vs.length / Math.max(durS, 1e-3),
    bitrate: vt.bitrate || Math.round((vs.reduce((a, s) => a + s.size, 0) * 8) / Math.max(durS, 1e-3)),
    description: decoderDescription(mp4.getTrackById(vt.id)),
    videoSamples: vs,
    audio: at ? audioInfo(mp4, at, samples[at.id]) : null,
  };
  const decCodec = meta.codec.startsWith('hev1') ? meta.codec.replace('hev1', 'hvc1') : meta.codec;
  const support = await VideoDecoder.isConfigSupported({
    codec: decCodec, codedWidth: meta.width, codedHeight: meta.height, description: meta.description,
  }).catch(() => ({ supported: false }));
  if (!support.supported) {
    const name = /^(hvc1|hev1)/.test(meta.codec) ? 'HEVC (H.265)' : meta.codec;
    throw new Error(`This browser can't decode ${name} video. Try Safari or Chrome/Edge on a computer with hardware ${name} support, or export the clip as H.264.`);
  }
  meta.displayWidth = rot % 180 ? meta.height : meta.width;
  meta.displayHeight = rot % 180 ? meta.width : meta.height;
  return meta;
}

function decoderDescription(trak) {
  for (const e of trak.mdia.minf.stbl.stsd.entries) {
    const box = e.avcC || e.hvcC || e.vpcC || e.av1C;
    if (box) {
      const s = new DataStream(undefined, 0, Endianness.BIG_ENDIAN);
      box.write(s);
      return new Uint8Array(s.buffer, 8); // drop box header
    }
  }
  return undefined;
}

function audioInfo(mp4, at, samples) {
  const entry = mp4.getTrackById(at.id).mdia.minf.stbl.stsd.entries[0];
  const codec = at.codec.startsWith('mp4a') ? 'aac' : at.codec.startsWith('Opus') || at.codec === 'opus' ? 'opus' : null;
  let description;
  try {
    description = entry.esds?.esd?.descs?.[0]?.descs?.[0]?.data;
  } catch {}
  return {
    codec,
    codecString: at.codec,
    channels: at.audio?.channel_count ?? 2,
    sampleRate: at.audio?.sample_rate ?? 48000,
    description: description ? new Uint8Array(description) : undefined,
    samples,
  };
}

export function summary(meta) {
  const fps = Math.abs(meta.fps - Math.round(meta.fps)) < 0.02 ? Math.round(meta.fps) : meta.fps.toFixed(2);
  const codec = meta.codec.startsWith('hvc') || meta.codec.startsWith('hev') ? 'HEVC'
    : meta.codec.startsWith('avc') ? 'H.264' : meta.codec.split('.')[0].toUpperCase();
  return `${meta.displayWidth}×${meta.displayHeight} · ${fps} fps · ${codec} · ${(meta.bitrate / 1e6).toFixed(1)} Mbps${meta.audio ? ' · audio' : ''}`;
}

// ---------------------------------------------------------------- backgrounds

async function pictureData(source, maxSide = 4096) {
  const sw = source.videoWidth || source.width;
  const sh = source.videoHeight || source.height;
  const s = Math.min(1, maxSide / Math.max(sw, sh));
  const c = new OffscreenCanvas(Math.max(2, Math.round(sw * s)), Math.max(2, Math.round(sh * s)));
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(source, 0, 0, c.width, c.height);
  return ctx.getImageData(0, 0, c.width, c.height);
}

export async function loadImageBitmap(file) {
  return createImageBitmap(file, { imageOrientation: 'from-image' });
}

/** Seeks and waits until the frame is really decoded (phones may report "seeked" before that). */
async function seek(video, t) {
  if (!(Math.abs(video.currentTime - t) < 1e-3 && video.readyState >= 2)) {
    await new Promise((resolve) => {
      video.addEventListener('seeked', () => resolve(), { once: true });
      video.currentTime = t;
    });
  }
  if (video.requestVideoFrameCallback && video.readyState < 2) {
    await new Promise((resolve) => {
      const id = video.requestVideoFrameCallback(() => resolve());
      setTimeout(() => { video.cancelVideoFrameCallback?.(id); resolve(); }, 400);
    });
  }
}

/** True when a drawn frame is empty (one flat colour), i.e. the browser gave no picture. */
function isBlank(img) {
  const d = img.data;
  let lo = 255, hi = 0;
  const step = Math.max(4, Math.floor(d.length / 4 / 2000) * 4);
  for (let i = 0; i < d.length; i += step) {
    const v = (d[i] + d[i + 1] + d[i + 2]) / 3;
    if (v < lo) lo = v;
    if (v > hi) hi = v;
    if (hi - lo > 6) return false;
  }
  return true;
}

/** Plays a moment so mobile browsers start decoding pictures for this element. */
async function wake(video) {
  try { await video.play(); await new Promise((r) => setTimeout(r, 120)); } catch { /* autoplay blocked */ }
  video.pause();
}

export function videoElement(url) {
  return new Promise((resolve, reject) => {
    const v = document.createElement('video');
    v.muted = true;
    v.playsInline = true;
    v.preload = 'auto';
    v.setAttribute('playsinline', '');
    // kept in the page (invisible): phones don't decode pictures for detached videos
    v.style.cssText = 'position:fixed;left:0;top:0;width:2px;height:2px;opacity:0;pointer-events:none';
    document.body.append(v);
    v.src = url;
    v.addEventListener('loadeddata', async () => { await wake(v); resolve(v); }, { once: true });
    v.addEventListener('error', () => reject(new Error('Cannot read video')), { once: true });
  });
}

const isDefaultPlacement = (p) => !p || (p.scale === 1 && !p.panX && !p.panY);
const cssHex = (argb) => '#' + ((argb >>> 0) & 0xffffff).toString(16).padStart(6, '0');

/** Upright picture at dw x dh with the user's size/position (null = plain cover). */
async function placedPicture(engine, source, dw, dh, placement, maxSide) {
  if (isDefaultPlacement(placement)) return pictureData(source, maxSide);
  const sw = source.videoWidth || source.width;
  const sh = source.videoHeight || source.height;
  const r = engine.placeRect(sw, sh, dw, dh, false, placement.scale, placement.panX || 0, placement.panY || 0);
  const c = new OffscreenCanvas(dw, dh);
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.fillStyle = cssHex(placement.fill ?? 0xff000000);
  ctx.fillRect(0, 0, dw, dh);
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(source, r.x, r.y, r.w, r.h);
  return ctx.getImageData(0, 0, dw, dh);
}

const even = (v) => Math.max(2, Math.round(v / 2) * 2);
function parseAspect(a) {
  if (!a || a === 'original') return null;
  const [x, y] = a.split(':').map(Number);
  return x > 0 && y > 0 ? x / y : null;
}

/**
 * Output canvas for a source stored at W x H with a clockwise display
 * rotation. CW x CH is in stored orientation (the rotation tag is kept);
 * rect is where the source video sits on it.
 */
export function layoutFor(engine, W, H, rot, aspect, fit, person) {
  const side = rot % 180 !== 0;
  const dW = side ? H : W, dH = side ? W : H;
  const r = parseAspect(aspect);
  let cw = dW, ch = dH;
  if (r) {
    const short = Math.min(dW, dH);
    if (r >= 1) { ch = short; cw = even(short * r); } else { cw = short; ch = even(short / r); }
  }
  const CW = side ? ch : cw, CH = side ? cw : ch;
  const ps = person?.scale ?? 1, px = person?.x ?? 0, py = person?.y ?? 0;
  const moved = ps !== 1 || px !== 0 || py !== 0;
  const identity = CW === W && CH === H && !moved;
  let rect;
  if (identity) rect = { x: 0, y: 0, w: W, h: H };
  else if (!moved) rect = engine.placeRect(W, H, CW, CH, fit);
  else {
    // speaker placed upright (dragging follows the finger), then into stored orientation
    const d = engine.placeRect(dW, dH, cw, ch, fit, ps, px, py);
    const sw = CW, sh = CH;
    rect = rot === 90 ? { x: d.y, y: sh - (d.x + d.w), w: d.h, h: d.w }
      : rot === 180 ? { x: sw - (d.x + d.w), y: sh - (d.y + d.h), w: d.w, h: d.h }
        : rot === 270 ? { x: sw - (d.y + d.h), y: d.x, w: d.h, h: d.w } : d;
  }
  return { CW, CH, dispW: cw, dispH: ch, rect, identity, W, H };
}

/**
 * Per-frame background provider. Pictures are written into `target`
 * (engine.bg for the source-shaped frame, else the canvas buffer).
 */
async function backgroundFor(engine, bg, rotation, matrix, full, L, target) {
  const tw = L.CW, th = L.CH;
  const put = (img) => engine.setBackgroundPicture(img, rotation, matrix, full, target, tw, th);
  const dispW = L.dispW, dispH = L.dispH;
  switch (bg.type) {
    case 'color':
      return async () => ({ mode: 0, color: engine.yuvColor(bg.argb, matrix, full) });
    case 'blur':
      return async () => ({ mode: 2, blur: bg.amount });
    case 'image': {
      put(await placedPicture(engine, bg.bitmap, dispW, dispH, bg.placement, 4096));
      return async () => ({ mode: 1 });
    }
    case 'video': {
      const v = bg.element;
      const dur = v.duration || 1;
      return async (tSec) => {
        await seek(v, tSec % dur);
        put(await placedPicture(engine, v, dispW, dispH, bg.placement, 1920));
        return { mode: 1 };
      };
    }
  }
  throw new Error('unknown background');
}

/** Person in front of the background on the output canvas; returns the output buffer. */
function composeFrame(eng, L, spec, canvasBuf, outBuf) {
  const outlined = () => {
    if (L.outline) eng.M._hbrw_outline(eng.e, eng.dst, L.W, L.H, L.outline.yuv, L.outline.width, L.outline.glow);
  };
  if (L.identity) {
    eng.composite(spec);
    outlined();
    return eng.dst;
  }
  const M = eng.M, { W, H, CW, CH } = L;
  if (spec.mode === 0) M._hbrw_fill_i420(canvasBuf, CW, CH, spec.color);
  else if (spec.mode === 2) {
    eng.blit(eng.src, W, H, canvasBuf, CW, CH, eng.placeRect(W, H, CW, CH, false));
    M._hbrw_blur_i420(canvasBuf, CW, CH, spec.blur * 1.5);
  }
  if (spec.mode === 2) eng.composite(spec);
  else {
    eng.crop(canvasBuf, CW, CH, L.rect, eng.bg, W, H);
    eng.composite({ mode: 1 });
  }
  outlined();
  eng.blit(canvasBuf, CW, CH, outBuf, CW, CH, { x: 0, y: 0, w: CW, h: CH });
  eng.blit(eng.dst, W, H, outBuf, CW, CH, L.rect);
  return outBuf;
}

// ---------------------------------------------------------------- preview

/** One processed frame, upright, drawn into `canvas`. */
export async function renderPreview({ videoEl, canvas, timeS, bg, settings, landscape, frame, captions, outline }) {
  const M = await loadCore();
  await seek(videoEl, timeS);
  const maxSide = 960;
  const s = Math.min(1, maxSide / Math.max(videoEl.videoWidth, videoEl.videoHeight));
  const w = Math.max(2, Math.round((videoEl.videoWidth * s) / 2) * 2);
  const h = Math.max(2, Math.round((videoEl.videoHeight * s) / 2) * 2);
  const c = new OffscreenCanvas(w, h);
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(videoEl, 0, 0, w, h);
  let rgba = ctx.getImageData(0, 0, w, h);
  for (let tries = 0; tries < 2 && isBlank(rgba); tries++) {
    // the browser gave an empty picture: wake the decoder and read again
    await wake(videoEl);
    await seek(videoEl, timeS + (tries + 1) * 1e-3);
    ctx.drawImage(videoEl, 0, 0, w, h);
    rgba = ctx.getImageData(0, 0, w, h);
  }
  if (isBlank(rgba)) throw new Error('This browser did not give a picture for this moment of the video. Try another moment, or export directly.');
  const eng = new Engine(M, w, h, { temporal: 0, ...settings });
  try {
    eng.rgbaToI420(rgba, eng.src, w, h, 1, true);
    const seg = await segmenter('IMAGE', landscape);
    const mask = personMask(seg.segment(c));
    eng.refine(mask.data, mask.w, mask.h, 0);
    const L = layoutFor(eng, w, h, 0, frame?.aspect, frame?.fit, frame?.person);
    if (outline) L.outline = { yuv: eng.yuvColor(outline.argb, 1, true), width: outline.width, glow: outline.glow ? 1 : 0 };
    let canvasBuf = 0, outBuf = 0;
    if (!L.identity) {
      canvasBuf = M._hbrw_alloc(i420Size(L.CW, L.CH));
      outBuf = M._hbrw_alloc(i420Size(L.CW, L.CH));
    }
    try {
      const next = await backgroundFor(eng, bg, 0, 1, true, L, L.identity ? eng.bg : canvasBuf);
      const out = composeFrame(eng, L, await next(timeS), canvasBuf, outBuf);
      if (captions?.enabled) {
        const cp = new CaptionPainter(captions, L.CW, L.CH, 0);
        cp.draw(M, out, L.CW, L.CH, timeS * 1000, 1, true);
        cp.free(M);
      }
      canvas.width = L.CW;
      canvas.height = L.CH;
      canvas.getContext('2d').putImageData(eng.toRgba(out, L.CW, L.CH, 1, true), 0, 0);
    } finally {
      if (canvasBuf) M._hbrw_free(canvasBuf);
      if (outBuf) M._hbrw_free(outBuf);
    }
  } finally {
    eng.destroy();
  }
}

// ---------------------------------------------------------------- soundtrack

/**
 * Mixes the video's own sound with music (looped, faded, lowered while the
 * person talks) and encodes it. Returns { codec, sampleRate, channels, chunks }.
 */
async function mixSoundtrack(file, durationS, sound, offsetS = 0) {
  const rate = 48000;
  const frames = Math.max(1, Math.round(durationS * rate));
  const dec = new OfflineAudioContext(2, 1, rate);
  const decode = async (blob) => dec.decodeAudioData(await blob.arrayBuffer());
  let voice = null;
  try { voice = await decode(file); } catch { voice = null; } // video without sound
  const music = sound.music ? await decode(sound.music) : null;

  const ctx = new OfflineAudioContext(2, frames, rate);
  if (voice) {
    const src = ctx.createBufferSource();
    src.buffer = voice;
    const g = ctx.createGain();
    g.gain.value = sound.voiceVolume ?? 1;
    src.connect(g).connect(ctx.destination);
    src.start(Math.max(0, offsetS));
  }
  if (music) {
    const src = ctx.createBufferSource();
    src.buffer = music;
    src.loop = true;
    const g = ctx.createGain();
    const vol = sound.musicVolume ?? 0.3;
    // ducking curve from the voice loudness, 20 ms steps
    const step = 0.02, n = Math.max(2, Math.ceil(durationS / step) + 1);
    const curve = new Float32Array(n).fill(vol);
    if (voice && sound.duck !== false) {
      const ch0 = voice.getChannelData(0);
      const ch1 = voice.numberOfChannels > 1 ? voice.getChannelData(1) : ch0;
      const per = Math.round(voice.sampleRate * step);
      let env = 0, duck = 1;
      const shift = Math.round(Math.max(0, offsetS) / step);
      for (let i = 0; i < n; i++) {
        let peak = 0;
        const k = i - shift;
        for (let j = Math.max(0, k * per), e = k < 0 ? 0 : Math.min(ch0.length, (k + 1) * per); j < e; j++) {
          peak = Math.max(peak, Math.abs(ch0[j]), Math.abs(ch1[j]));
        }
        env += (peak - env) * (peak > env ? 0.8 : 0.06);
        const t = Math.min(1, Math.max(0, (env - 0.015) / (0.07 - 0.015)));
        const target = 1 - 0.65 * t * t * (3 - 2 * t);
        duck += (target - duck) * (target < duck ? 0.5 : 0.06);
        curve[i] = vol * duck;
      }
    }
    // fade in 0.3 s, fade out 1.5 s (shorter on very short clips)
    const fin = Math.min(0.3, durationS / 8), fout = Math.min(1.5, durationS / 4);
    for (let i = 0; i < n; i++) {
      const t = i * step;
      curve[i] *= Math.min(1, t / fin, Math.max(0, durationS - t) / fout);
    }
    g.gain.setValueCurveAtTime(curve, 0, Math.max(0.05, durationS));
    src.connect(g).connect(ctx.destination);
    // start at the chosen point of the song and loop back to it
    const off = Math.min(Math.max(0, (sound.musicStartMs || 0) / 1000), Math.max(0, music.duration - 1));
    src.loopStart = off;
    src.loopEnd = music.duration;
    src.start(0, off);
  }
  const mixed = await ctx.startRendering();

  // gentle limiter: transparent below 0.9
  const L = mixed.getChannelData(0), R = mixed.getChannelData(1);
  for (const c of [L, R]) for (let i = 0; i < c.length; i++) {
    const a = Math.abs(c[i]);
    if (a > 0.9) c[i] = Math.sign(c[i]) * (0.9 + 0.1 * Math.tanh((a - 0.9) / 0.1));
  }

  let codec = null;
  for (const [c, mux] of [['mp4a.40.2', 'aac'], ['opus', 'opus']]) {
    try {
      const r = await AudioEncoder.isConfigSupported({ codec: c, sampleRate: rate, numberOfChannels: 2, bitrate: 192000 });
      if (r.supported) { codec = { config: r.config, mux }; break; }
    } catch {}
  }
  if (!codec) throw new Error("This browser can't encode audio");
  const chunks = [];
  let err = null;
  const enc = new AudioEncoder({ output: (chunk, meta) => chunks.push({ chunk, meta }), error: (e) => (err = e) });
  enc.configure(codec.config);
  const block = 4096;
  for (let i = 0; i < frames; i += block) {
    const n = Math.min(block, frames - i);
    const data = new Float32Array(n * 2);
    data.set(L.subarray(i, i + n), 0);
    data.set(R.subarray(i, i + n), n);
    const ad = new AudioData({ format: 'f32-planar', sampleRate: rate, numberOfFrames: n, numberOfChannels: 2, timestamp: Math.round((i * 1e6) / rate), data });
    enc.encode(ad);
    ad.close();
    if (err) throw err;
  }
  await enc.flush();
  enc.close();
  if (err) throw err;
  return { codec: codec.mux, sampleRate: rate, channels: 2, chunks };
}

// ---------------------------------------------------------------- export

async function pickEncoder(meta, W, H) {
  const hevc = /^(hvc1|hev1)/.test(meta.codec);
  const floor = W * H * meta.fps * (hevc ? 0.07 : 0.1);
  const bitrate = Math.round(Math.max(meta.bitrate, floor));
  const lvl = W * H > 2228224 ? '33' : '2a'; // L5.1 for > 1080p, else L4.2
  const options = [
    ...(hevc ? [['hvc1.1.6.L153.B0', 'hevc'], ['hvc1.1.6.L123.B0', 'hevc']] : []),
    [`avc1.6400${lvl === '33' ? '33' : '2a'}`, 'avc'], ['avc1.640033', 'avc'], ['avc1.4d0033', 'avc'],
    ...(hevc ? [] : [['hvc1.1.6.L153.B0', 'hevc']]),
    ['vp09.00.51.08', 'vp9'], ['av01.0.13M.08', 'av1'],
  ];
  for (const accel of ['prefer-hardware', 'no-preference']) {
    for (const [codec, mux] of options) {
      const config = {
        codec, width: W, height: H, bitrate, framerate: meta.fps, bitrateMode: 'variable',
        latencyMode: 'quality', hardwareAcceleration: accel,
        ...(mux === 'avc' ? { avc: { format: 'avc' } } : {}),
        ...(mux === 'hevc' ? { hevc: { format: 'hevc' } } : {}),
      };
      try {
        const r = await VideoEncoder.isConfigSupported(config);
        if (r.supported) return { config: r.config, mux };
      } catch {}
    }
  }
  throw new Error(`This browser can't encode ${W}×${H} video`);
}

/**
 * Full export. onProgress({fraction, frames, total, fps}). Returns
 * {blob, warnings, encoder}. `signal` cancels.
 */
// ---------------------------------------------------------------- intro / outro clips

export const TRANSITIONS = [
  ['cut', 'Cut', 0], ['fade', 'Fade', 1], ['black', 'Dip to black', 2], ['flash', 'Flash', 3],
  ['slide', 'Slide', 4], ['push', 'Push', 5], ['up', 'Slide up', 6], ['zoomin', 'Zoom in', 7],
  ['zoomout', 'Zoom out', 8], ['circle', 'Circle', 9], ['wipe', 'Wipe', 10], ['spin', 'Spin', 11],
];
const trCode = (id) => (TRANSITIONS.find((t) => t[0] === id) || TRANSITIONS[1])[2];

/** Upright clip picture filling dw x dh: cover, or the whole picture over a blurred copy. */
function clipPicture(source, dw, dh, fit) {
  const sw = source.videoWidth || source.width, sh = source.videoHeight || source.height;
  const c = new OffscreenCanvas(dw, dh);
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.imageSmoothingQuality = 'high';
  const cover = Math.max(dw / sw, dh / sh), contain = Math.min(dw / sw, dh / sh);
  const draw = (k) => ctx.drawImage(source, (dw - sw * k) / 2, (dh - sh * k) / 2, sw * k, sh * k);
  if (fit) {
    ctx.filter = `blur(${Math.round(Math.min(dw, dh) / 30)}px) brightness(0.7)`;
    draw(cover * 1.1);
    ctx.filter = 'none';
    draw(contain);
  } else draw(cover);
  return ctx.getImageData(0, 0, dw, dh);
}

/** Total length of the clips (seconds). */
export function clipsDuration(list) {
  return (list || []).reduce((a, c) => a + clipLength(c), 0);
}
function clipLength(c) {
  if (c.kind === 'video') return Math.min(c.element?.duration || 0, c.maxS || 60);
  return c.durationS || 3;
}

/**
 * Puts output frames in order with the chosen transitions: each part
 * enters over `trS` seconds from the last frame of the part before it
 * (or from black), and the film can end by fading to black.
 */
class Sequencer {
  constructor(M, CW, CH, rot, black, { trS = 0.8, fadeOut = false, endUs = 0 } = {}) {
    this.M = M; this.CW = CW; this.CH = CH; this.rot = rot;
    this.size = i420Size(CW, CH);
    this.prev = M._hbrw_alloc(this.size);
    this.out = M._hbrw_alloc(this.size);
    this.out2 = M._hbrw_alloc(this.size);
    this.black = M._hbrw_alloc(this.size);
    M._hbrw_fill_i420(this.black, CW, CH, black);
    M.HEAPU8.copyWithin(this.prev, this.black, this.black + this.size);
    this.trS = trS; this.fadeOut = fadeOut; this.endUs = endUs;
    this.type = 0; this.startUs = 0;
  }
  /** A new part starts at output time startUs, entering with transition `id`. */
  begin(id, startUs) { this.type = trCode(id); this.startUs = startUs; }
  /** Returns the buffer to encode for this frame. */
  frame(ptr, outUs) {
    const M = this.M;
    let cur = ptr;
    const local = (outUs - this.startUs) / 1e6;
    if (this.type && local < this.trS) {
      M._hbrw_transition(this.prev === cur ? this.black : this.prevSnap(), cur, this.out, this.CW, this.CH, this.rot, this.type, Math.max(0, local) / this.trS);
      cur = this.out;
    } else this.snapDirty = true;
    if (this.fadeOut && this.endUs && outUs > this.endUs - this.trS * 1e6) {
      const t = Math.min(1, (outUs - (this.endUs - this.trS * 1e6)) / (this.trS * 1e6));
      M._hbrw_transition(cur, this.black, this.out2, this.CW, this.CH, this.rot, 1, t);
      cur = this.out2;
    }
    this.last = cur;
    this.lastSrc = ptr;
    return cur;
  }
  /** Freezes the last shown frame as the start of the next transition. */
  hold() {
    if (this.last) this.M.HEAPU8.copyWithin(this.prev, this.last, this.last + this.size);
    this.held = true;
  }
  prevSnap() { return this.prev; }
  free() { for (const p of [this.prev, this.out, this.out2, this.black]) this.M._hbrw_free(p); }
}

/** Renders the frames of one clip (picture or video) into `buf`, calling emit(ptr, localUs, durUs). */
async function renderClip(eng, clip, L, rot, matrix, full, buf, tmp, fps, emit, signal) {
  const M = eng.M, { CW, CH } = L, dur = 1e6 / fps;
  const total = clipLength(clip);
  const n = Math.max(1, Math.round(total * fps));
  if (clip.kind === 'image') {
    eng.setBackgroundPicture(clipPicture(clip.bitmap, L.dispW, L.dispH, clip.fit), rot, matrix, full, buf, CW, CH);
    for (let i = 0; i < n; i++) {
      if (signal?.aborted) throw new DOMException('cancelled', 'AbortError');
      let ptr = buf;
      if (clip.motion === 'in' || clip.motion === 'out') {
        const p = i / Math.max(1, n - 1), z = 0.14 * (clip.motion === 'in' ? p : 1 - p);
        M._hbrw_zoom(buf, tmp, CW, CH, 1 + z);
        ptr = tmp;
      }
      await emit(ptr, i * dur, dur);
    }
  } else {
    const v = clip.element;
    for (let i = 0; i < n; i++) {
      if (signal?.aborted) throw new DOMException('cancelled', 'AbortError');
      await seek(v, Math.min(v.duration - 0.01, i / fps));
      eng.setBackgroundPicture(clipPicture(v, L.dispW, L.dispH, clip.fit), rot, matrix, full, buf, CW, CH);
      await emit(buf, i * dur, dur);
    }
  }
}

export async function exportVideo({ meta, bg, settings, onProgress, signal, frame, sound, file, captions, sequence, outline }) {
  const M = await loadCore();
  const W = meta.width, H = meta.height, rot = meta.rotation;
  const warnings = [];
  const eng = new Engine(M, W, H, settings);
  const L = layoutFor(eng, W, H, rot, frame?.aspect, frame?.fit, frame?.person);
  const CW = L.CW, CH = L.CH;
  const canvasBuf = L.identity ? 0 : M._hbrw_alloc(i420Size(CW, CH));
  const outBuf = L.identity ? 0 : M._hbrw_alloc(i420Size(CW, CH));
  const seg = await segmenter('VIDEO', meta.displayWidth > meta.displayHeight);
  const { config: encConfig, mux } = await pickEncoder(meta, CW, CH);

  const audio = meta.audio;
  let mixed = null;
  const before = sequence?.before || [], after = sequence?.after || [];
  const introS = clipsDuration(before), outroS = clipsDuration(after);
  const hasClips = before.length + after.length > 0;
  const wantsMix = (sound && (sound.music || (sound.voiceVolume ?? 1) !== 1)) || hasClips;
  if (wantsMix) {
    try {
      mixed = await mixSoundtrack(file, introS + meta.durationS + outroS, sound || {}, introS);
    } catch (e) {
      console.warn('soundtrack mix failed', e);
      warnings.push(hasClips ? `The sound could not be prepared (${e.message || e}).` : `The music could not be added (${e.message || e}); the original sound was kept.`);
    }
  }
  const muxAudio = !mixed && audio && audio.codec && audio.description !== undefined;
  if (!mixed && audio && !muxAudio) warnings.push('The audio format could not be copied, so it was left out.');
  const audioCfg = mixed ? { codec: mixed.codec, numberOfChannels: mixed.channels, sampleRate: mixed.sampleRate }
    : muxAudio ? { codec: audio.codec, numberOfChannels: audio.channels, sampleRate: audio.sampleRate } : null;
  const muxer = new Muxer({
    target: new ArrayBufferTarget(),
    video: { codec: mux, width: CW, height: CH, rotation: rot },
    ...(audioCfg ? { audio: audioCfg } : {}),
    fastStart: 'in-memory',
    firstTimestampBehavior: 'offset',
  });

  let encError = null;
  const encoder = new VideoEncoder({
    output: (chunk, md) => muxer.addVideoChunk(chunk, md),
    error: (e) => (encError = e),
  });
  encoder.configure(encConfig);

  const frameQueue = [];
  let decError = null;
  const decoder = new VideoDecoder({ output: (f) => frameQueue.push(f), error: (e) => (decError = e) });
  decoder.configure({
    codec: meta.codec.startsWith('hev1') ? meta.codec.replace('hev1', 'hvc1') : meta.codec,
    codedWidth: W, codedHeight: H, description: meta.description, hardwareAcceleration: 'no-preference',
  });

  let matrix = 1, full = false, colorSpace = null, nextBg = null, firstTs = null;
  const introUs = Math.round(introS * 1e6);
  const mainUs = Math.round(meta.durationS * 1e6);
  const endUs = introUs + mainUs + Math.round(outroS * 1e6);
  let seq = null, clipBuf = 0, clipTmp = 0, lastOutUs = 0, lastDur = 0;
  const useSeq = hasClips || sequence?.fadeIn || sequence?.fadeOut;
  const encodePtr = async (ptr, outUs, dur) => {
    while (encoder.encodeQueueSize > 4) await tick();
    const vf = new VideoFrame(eng.view(ptr, i420Size(CW, CH)), {
      format: 'I420', codedWidth: CW, codedHeight: CH, timestamp: outUs, duration: dur,
      ...(colorSpace ? { colorSpace } : {}),
    });
    encoder.encode(vf, { keyFrame: encodedCount % keyEvery === 0 });
    vf.close();
    encodedCount++;
    lastOutUs = outUs; lastDur = dur;
  };
  let encodedCount = 0;
  const fpsOut = meta.fps || 30;
  const runClips = async (list, startUs) => {
    let at = startUs;
    for (const clip of list) {
      seq.begin(clip.transition || 'fade', at);
      await renderClip(eng, clip, L, rot, matrix, full, clipBuf, clipTmp, fpsOut, async (ptr, localUs, dur) => {
        const t = Math.round(at + localUs);
        await encodePtr(seq.frame(ptr, t), t, dur);
      }, signal);
      seq.hold();
      at += Math.round(clipLength(clip) * 1e6);
      onProgress?.({ fraction: done / total, frames: done, total, fps: 0, stage: 'clips' });
    }
    return at;
  };
  const painter = captions?.enabled && captions.cues?.length ? new CaptionPainter(captions, L.dispW, L.dispH, rot) : null;
  const total = meta.videoSamples.length;
  const keyEvery = Math.max(1, Math.round(meta.fps));
  let done = 0;
  const t0 = performance.now();
  const sw = Math.max(2, Math.round((W * 256) / Math.min(W, H) / 2) * 2);
  const sh = Math.max(2, Math.round((H * 256) / Math.min(W, H) / 2) * 2);
  const segCanvas = new OffscreenCanvas(rot % 180 ? sh : sw, rot % 180 ? sw : sh);
  const segCtx = segCanvas.getContext('2d');
  const tmpCanvas = new OffscreenCanvas(sw, sh);
  const tmpCtx = tmpCanvas.getContext('2d');
  let lastTs = -1;

  const processFrame = async (frame) => {
    try {
      if (!colorSpace) {
        colorSpace = frame.colorSpace?.toJSON?.() ?? null;
        matrix = matrixOf(frame.colorSpace);
        full = !!frame.colorSpace?.fullRange;
        nextBg = await backgroundFor(eng, bg, rot, matrix, full, L, L.identity ? eng.bg : canvasBuf);
        if (outline) L.outline = { yuv: eng.yuvColor(outline.argb, matrix, full), width: outline.width, glow: outline.glow ? 1 : 0 };
        if (useSeq) {
          seq = new Sequencer(M, CW, CH, rot, eng.yuvColor(0xff000000, matrix, full),
            { trS: sequence?.transitionS ?? 0.8, fadeOut: !!sequence?.fadeOut, endUs });
          clipBuf = M._hbrw_alloc(i420Size(CW, CH));
          clipTmp = M._hbrw_alloc(i420Size(CW, CH));
          await runClips(before, 0);
          seq.begin(before.length ? (sequence?.into || 'fade') : (sequence?.fadeIn ? 'fade' : 'cut'), introUs);
        }
      }
      const fw = frame.visibleRect?.width ?? frame.displayWidth;
      const fh = frame.visibleRect?.height ?? frame.displayHeight;
      if (fw !== W || fh !== H) throw new Error(`Unexpected frame size ${fw}×${fh}`);
      const cw = (W + 1) >> 1, ch = (H + 1) >> 1;
      if (frame.format === 'I420' || frame.format === 'I420A') {
        const layout = [{ offset: 0, stride: W }, { offset: W * H, stride: cw }, { offset: W * H + cw * ch, stride: cw }];
        const tmp = new Uint8Array(eng.size);
        await frame.copyTo(tmp, { layout: layout.concat(frame.format === 'I420A' ? [] : []) , rect: frame.visibleRect });
        eng.heap.set(tmp, eng.src);
      } else if (frame.format === 'NV12') {
        const tmp = new Uint8Array(W * H + cw * ch * 2);
        await frame.copyTo(tmp, { layout: [{ offset: 0, stride: W }, { offset: W * H, stride: cw * 2 }], rect: frame.visibleRect });
        eng.heap.set(tmp, eng.tmp);
        M._hbrw_nv12_to_i420(eng.tmp, W, H, eng.src);
      } else {
        // GPU-backed or high-bit-depth frame: read through a canvas (8-bit)
        const c = new OffscreenCanvas(W, H);
        const cx = c.getContext('2d', { willReadFrequently: true });
        cx.drawImage(frame, 0, 0, W, H);
        eng.rgbaToI420(cx.getImageData(0, 0, W, H), eng.src, W, H, matrix, full);
      }
      const ts = frame.timestamp, dur = frame.duration ?? Math.round(1e6 / meta.fps);
      frame.close();

      // segmentation on an upright 256 px copy
      tmpCtx.putImageData(eng.smallRgba(sw, sh, matrix, full), 0, 0);
      segCtx.save();
      segCtx.translate(segCanvas.width / 2, segCanvas.height / 2);
      segCtx.rotate((rot * Math.PI) / 180);
      segCtx.drawImage(tmpCanvas, -sw / 2, -sh / 2);
      segCtx.restore();
      let tsMs = ts / 1000;
      if (tsMs <= lastTs) tsMs = lastTs + 1;
      lastTs = tsMs;
      const mask = personMask(seg.segmentForVideo(segCanvas, tsMs));
      eng.refine(mask.data, mask.w, mask.h, rot);
      const outPtr = composeFrame(eng, L, await nextBg(ts / 1e6), canvasBuf, outBuf);
      if (painter) {
        firstTs ??= ts;
        painter.draw(M, outPtr, CW, CH, (ts - firstTs) / 1000, matrix, full);
      }

      firstTs ??= ts;
      if (seq) {
        const t = introUs + (ts - firstTs);
        await encodePtr(seq.frame(outPtr, t), t, dur);
      } else {
        await encodePtr(outPtr, ts, dur);
      }
      done++;
      if (done % 3 === 0 || done === total) {
        const secs = (performance.now() - t0) / 1000;
        onProgress?.({ fraction: done / total, frames: done, total, fps: done / secs });
      }
    } catch (e) {
      frame.close?.();
      throw e;
    }
  };

  const drain = async () => {
    while (frameQueue.length) await processFrame(frameQueue.shift());
  };

  try {
    for (const s of meta.videoSamples) {
      if (signal?.aborted) throw new DOMException('cancelled', 'AbortError');
      if (decError) throw decError;
      if (encError) throw encError;
      decoder.decode(new EncodedVideoChunk({
        type: s.is_sync ? 'key' : 'delta',
        timestamp: Math.round((s.cts * 1e6) / s.timescale),
        duration: Math.round((s.duration * 1e6) / s.timescale),
        data: s.data,
      }));
      while (decoder.decodeQueueSize > 3) {
        await drain();
        await tick();
      }
      await drain();
    }
    await decoder.flush();
    await drain();
    if (seq && after.length) {
      seq.hold();
      seq.endUs = lastOutUs + lastDur + Math.round(outroS * 1e6);
      await runClips(after, lastOutUs + lastDur);
    }
    await encoder.flush();
    if (encError) throw encError;

    if (mixed) {
      for (const { chunk, meta: md } of mixed.chunks) muxer.addAudioChunk(chunk, md);
    } else if (muxAudio) {
      let first = true;
      for (const s of audio.samples) {
        muxer.addAudioChunkRaw(s.data, 'key', Math.round((s.cts * 1e6) / s.timescale),
          Math.round((s.duration * 1e6) / s.timescale),
          first ? { decoderConfig: { codec: audio.codecString, numberOfChannels: audio.channels, sampleRate: audio.sampleRate, description: audio.description } } : undefined);
        first = false;
      }
    }
    muxer.finalize();
    if (!done) throw new Error('No frames were exported');
    return {
      blob: new Blob([muxer.target.buffer], { type: 'video/mp4' }),
      warnings,
      encoder: encConfig.codec,
      frames: encodedCount,
    };
  } finally {
    for (const f of frameQueue) f.close();
    if (decoder.state !== 'closed') decoder.close();
    if (encoder.state !== 'closed') encoder.close();
    if (canvasBuf) M._hbrw_free(canvasBuf);
    if (outBuf) M._hbrw_free(outBuf);
    painter?.free(M);
    seq?.free();
    if (clipBuf) M._hbrw_free(clipBuf);
    if (clipTmp) M._hbrw_free(clipTmp);
    eng.destroy();
  }
}

export { i420Size };
