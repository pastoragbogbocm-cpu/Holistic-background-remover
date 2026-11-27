import { demux, summary, renderPreview, exportVideo, loadImageBitmap, videoElement, TRANSITIONS, clipsDuration } from './pipeline.js';
import { PRESETS, HIGHLIGHTS, LANGUAGES, groupCues, editCue, transcribe } from './captions.js';

const $ = (id) => document.getElementById(id);
const SWATCHES = [0xff00b140, 0xff0047bb, 0xffffffff, 0xff000000, 0xff808080, 0xff2dd4bf, 0xfff59e0b, 0xffec4899];

const state = {
  file: null, url: null, meta: null, videoEl: null,
  kind: 'color', argb: SWATCHES[0], image: null, bgVideo: null, blur: 0.03,
  showOriginal: false, timeS: 0, rendering: false, again: false, abort: null, result: null,
  aspect: 'original', fit: false, placement: { scale: 1, panX: 0, panY: 0, fill: 0xff000000 },
  person: { scale: 1, x: 0, y: 0 }, dragWhat: 'person',
  cues: [], capOn: true, capStyle: { preset: 'pop', position: 'bottom', size: 1, textColor: 0xffffffff, highlightColor: HIGHLIGHTS[0], uppercase: false },
  capAbort: null,
};
const captions = () => (state.cues.length ? { enabled: state.capOn, cues: state.cues, style: { ...state.capStyle } } : null);
const SHAPES = [['original', 'Original'], ['9:16', '9:16'], ['1:1', '1:1'], ['4:5', '4:5'], ['16:9', '16:9']];
const frame = () => ({ aspect: state.aspect, fit: state.fit, person: { ...state.person } });
const sound = () => ({ music: state.music, musicVolume: +$('mvol').value, voiceVolume: +$('vvol').value, duck: $('duck').checked, musicStartMs: Math.round(+$('mstart').value * 1000) });

const hex = (argb) => '#' + (argb & 0xffffff).toString(16).padStart(6, '0');
const setErr = (m) => ($('err').textContent = m || '');

function settings() {
  return {
    smoothing: +$('smooth').value, softness: +$('soft').value,
    temporal: +$('temporal').value, clean: $('clean').checked,
  };
}

function background() {
  switch (state.kind) {
    case 'image': if (state.image) return { type: 'image', bitmap: state.image, placement: { ...state.placement } }; break;
    case 'video': if (state.bgVideo) return { type: 'video', element: state.bgVideo, placement: { ...state.placement } }; break;
    case 'blur': return { type: 'blur', amount: state.blur };
  }
  return { type: 'color', argb: state.argb };
}

// ---------- swatches
$('swatches').innerHTML = SWATCHES.map((c) =>
  `<button class="sw" style="background:${hex(c)}" data-c="${c}" aria-label="Colour ${hex(c)}" aria-pressed="${c === state.argb}"></button>`).join('');
$('swatches').addEventListener('click', (e) => {
  const b = e.target.closest('.sw');
  if (!b) return;
  state.argb = +b.dataset.c;
  markSwatches();
  schedule(true);
});
$('custom').addEventListener('input', (e) => {
  state.argb = 0xff000000 | parseInt(e.target.value.slice(1), 16);
  markSwatches();
  schedule();
});
function markSwatches() {
  for (const b of document.querySelectorAll('.sw')) b.setAttribute('aria-pressed', String(+b.dataset.c === state.argb));
}

// ---------- frame size
function shapeIcon(id) {
  const r = id === 'original' ? (state.meta ? state.meta.displayWidth / state.meta.displayHeight : 16 / 9)
    : id.split(':').reduce((a, b) => a / b);
  const box = 26, w = r >= 1 ? box : box * r, h = r >= 1 ? box / r : box;
  return `<i style="width:${w.toFixed(1)}px;height:${h.toFixed(1)}px"></i>`;
}
function drawShapes() {
  $('shapes').innerHTML = SHAPES.map(([id, label]) =>
    `<button class="shape" data-a="${id}" aria-pressed="${id === state.aspect}"><span style="height:26px;display:grid;place-items:center">${shapeIcon(id)}</span>${label}</button>`).join('');
  const on = state.aspect !== 'original';
  $('fitToggle').classList.toggle('hidden', !on);
  $('fitHint').classList.toggle('hidden', !on);
  for (const b of $('fitToggle').querySelectorAll('button')) b.setAttribute('aria-pressed', String((b.dataset.fit === '1') === state.fit));
  $('fitHint').textContent = state.fit
    ? 'The whole video is shown; your background fills the rest of the frame.'
    : 'The video fills the frame; the edges outside it are trimmed.';
  updateKeeps();
}
$('shapes').addEventListener('click', (e) => {
  const b = e.target.closest('.shape');
  if (!b) return;
  state.aspect = b.dataset.a;
  drawShapes();
  schedule(true);
});
$('fitToggle').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  state.fit = b.dataset.fit === '1';
  drawShapes();
  schedule(true);
});
function frameSize() {
  const m = state.meta;
  if (!m || state.aspect === 'original') return m ? [m.displayWidth, m.displayHeight] : null;
  const [x, y] = state.aspect.split(':').map(Number), r = x / y, s = Math.min(m.displayWidth, m.displayHeight);
  const ev = (v) => Math.max(2, Math.round(v / 2) * 2);
  return r >= 1 ? [ev(s * r), s] : [s, ev(s / r)];
}
function updateKeeps() {
  if (!state.meta) return;
  const snd = state.music ? ' Sound: voice + music, re-encoded.' : (+$('vvol').value !== 1 ? ' Sound: voice level changed, re-encoded.' : '');
  updateKeepsBase();
  if (snd) $('keeps').textContent = $('keeps').textContent.replace(', original audio copied untouched.', '.') + snd;
  if (state.cues?.length && state.capOn) $('keeps').textContent += ` Captions burned in (${state.cues.length}).`;
}
function updateKeepsBase() {
  if (state.aspect === 'original') {
    $('keeps').textContent = `Exports at ${summary(state.meta)}, same rotation and timing, original audio copied untouched.`;
  } else {
    const [w, h] = frameSize();
    $('keeps').textContent = `Exports a ${state.aspect} frame at ${w}×${h} (${state.fit ? 'whole video' : 'filled'}), same frame rate and timing, original audio copied untouched.`;
  }
}
drawShapes();

// ---------- background size and position
$('fillSw').innerHTML = SWATCHES.map((c) =>
  `<button class="sw" style="background:${hex(c)}" data-c="${c}" aria-label="Colour ${hex(c)}" aria-pressed="${c === state.placement.fill}"></button>`).join('');
$('fillSw').addEventListener('click', (e) => {
  const b = e.target.closest('.sw');
  if (!b) return;
  state.placement.fill = +b.dataset.c;
  for (const x of $('fillSw').querySelectorAll('.sw')) x.setAttribute('aria-pressed', String(+x.dataset.c === state.placement.fill));
  schedule(true);
});
function drawPlacement() {
  const movable = (state.kind === 'image' && state.image) || (state.kind === 'video' && state.bgVideo);
  $('place').classList.toggle('hidden', !movable);
  $('out').classList.add('movable');
  $('dragWhat').classList.toggle('hidden', !movable);
  if (!movable) state.dragWhat = 'person';
  for (const b of $('dragWhat').querySelectorAll('button')) b.setAttribute('aria-pressed', String(b.dataset.t === state.dragWhat));
  $('dragHint').textContent = state.dragWhat === 'bg'
    ? 'Drag the preview to move the background picture.'
    : 'Drag the preview to move the speaker. Make them smaller to show more background.';
  const p = state.person;
  $('pscale').value = p.scale;
  $('pscaleV').textContent = Math.round(p.scale * 100) + '%';
  $('resetPerson').classList.toggle('hidden', p.scale === 1 && !p.x && !p.y);
  $('scale').value = state.placement.scale;
  $('scaleV').textContent = Math.round(state.placement.scale * 100) + '%';
  $('fillRow').classList.toggle('hidden', state.placement.scale >= 1);
}
$('pscale').oninput = (e) => { state.person.scale = +e.target.value; drawPlacement(); schedule(); };
$('resetPerson').onclick = () => { state.person = { scale: 1, x: 0, y: 0 }; drawPlacement(); schedule(true); };
$('dragWhat').onclick = (e) => { const b = e.target.closest('button'); if (b) { state.dragWhat = b.dataset.t; drawPlacement(); } };
/** Speaker's size on the output frame (display px) for the current settings. */
function personSize() {
  const m = state.meta, [fw, fh] = frameSize();
  const sx = fw / m.displayWidth, sy = fh / m.displayHeight;
  const s = (state.fit ? Math.min(sx, sy) : Math.max(sx, sy)) * state.person.scale;
  return [fw, fh, m.displayWidth * s, m.displayHeight * s];
}
$('scale').oninput = (e) => { state.placement.scale = +e.target.value; drawPlacement(); schedule(); };
$('resetPlace').onclick = () => { Object.assign(state.placement, { scale: 1, panX: 0, panY: 0 }); drawPlacement(); schedule(true); };
{
  // drag the preview: the picture follows the finger
  let drag = null;
  const out = $('out');
  out.addEventListener('pointerdown', (e) => {
    if (!out.classList.contains('movable')) return;
    drag = { x: e.clientX, y: e.clientY };
    out.setPointerCapture(e.pointerId);
  });
  out.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const r = out.getBoundingClientRect();
    if (state.dragWhat === 'person') {
      // follow the finger exactly: pan -1..1 spans the free room
      const [fw, fh, pw, ph] = personSize();
      const k = fw / r.width, clamp = (v) => Math.max(-1, Math.min(1, v));
      const fx = fw - pw, fy = fh - ph;
      if (Math.abs(fx) >= 1) state.person.x = clamp(state.person.x + (2 * (e.clientX - drag.x) * k) / fx);
      if (Math.abs(fy) >= 1) state.person.y = clamp(state.person.y + (2 * (e.clientY - drag.y) * k) / fy);
      drag = { x: e.clientX, y: e.clientY };
      drawPlacement();
      schedule();
      return;
    }
    const sign = state.placement.scale >= 1 ? -1 : 1;
    const clamp = (v) => Math.max(-1, Math.min(1, v));
    state.placement.panX = clamp(state.placement.panX + sign * 2 * (e.clientX - drag.x) / r.width);
    state.placement.panY = clamp(state.placement.panY + sign * 2 * (e.clientY - drag.y) / r.height);
    drag = { x: e.clientX, y: e.clientY };
    schedule();
  });
  const end = () => { if (drag) { drag = null; schedule(true); } };
  out.addEventListener('pointerup', end);
  out.addEventListener('pointercancel', end);
}

// ---------- sound
function drawSound() {
  $('musicName').textContent = state.music ? state.music.name : 'No music';
  $('musicHint').textContent = state.music ? 'Loops to the end, fades out' : 'Add a song or beat from this device';
  $('musicPick').textContent = state.music ? 'Change' : 'Add music';
  $('musicDel').classList.toggle('hidden', !state.music);
  $('musicOpts').classList.toggle('hidden', !state.music);
  $('mvolV').textContent = Math.round(+$('mvol').value * 100) + '%';
  $('mstartV').textContent = mmss(+$('mstart').value);
  $('vvolV').textContent = Math.round(+$('vvol').value * 100) + '%';
  updateKeeps();
}
$('musicPick').onclick = () => $('musicFile').click();
function mmss(s) { return `${Math.floor(s / 60)}:${String(Math.floor(s) % 60).padStart(2, "0")}`; }
function setMusic(f) {
  state.music = f;
  const a = $('maudio');
  a.pause();
  if (state.musicUrl) URL.revokeObjectURL(state.musicUrl);
  state.musicUrl = f ? URL.createObjectURL(f) : null;
  $('mstart').value = 0;
  if (f) {
    a.src = state.musicUrl;
    a.onloadedmetadata = () => {
      $('mstart').max = Math.max(1, Math.floor(a.duration - 1));
      $('mlen').textContent = `Slide to choose the part of the song you want. Song length ${mmss(a.duration)}.`;
      drawSound();
    };
  } else a.removeAttribute('src');
  drawSound();
}
$('musicFile').onchange = (e) => { const f = e.target.files[0]; if (f) setMusic(f); };
$('musicDel').onclick = () => { $('musicFile').value = ''; setMusic(null); };
$('mstart').oninput = () => { drawSound(); if (!$('maudio').paused) $('maudio').currentTime = +$('mstart').value; };
$('mplay').onclick = () => {
  const a = $('maudio');
  if (!a.paused) { a.pause(); return; }
  a.currentTime = +$('mstart').value;
  a.play().catch(() => {});
};
$('maudio').onplay = $('maudio').onpause = () => ($('mplay').textContent = $('maudio').paused ? '▶' : '■');
$('mvol').oninput = drawSound;
$('vvol').oninput = drawSound;

// ---------- captions
$('capLang').innerHTML = LANGUAGES.map(([c, n]) => `<option value="${c}">${n}</option>`).join('');
$('capPresets').innerHTML = PRESETS.map((p) => `<button class="preset" data-p="${p}"><b>Aa</b>${p[0].toUpperCase() + p.slice(1)}</button>`).join('');
$('capHi').innerHTML = HIGHLIGHTS.map((c) => `<button class="sw" style="background:${hex(c)}" data-c="${c}" aria-label="Highlight ${hex(c)}"></button>`).join('');
const fmtT = (ms) => `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}`;
function drawCaptions() {
  const st = state.capStyle, have = state.cues.length > 0;
  $('capOpts').classList.toggle('hidden', !have);
  $('capGo').textContent = have ? 'Generate again' : 'Generate captions';
  $('capGo').disabled = !state.meta || !!state.capAbort;
  $('capOn').checked = state.capOn;
  for (const b of $('capPresets').querySelectorAll('.preset')) {
    const p = b.dataset.p, on = p === st.preset;
    b.setAttribute('aria-pressed', String(on));
    const mark = b.querySelector('b');
    mark.style.background = p === 'box' ? 'rgba(0,0,0,.75)' : 'none';
    mark.style.color = p === 'clean' ? '#fff' : hex(st.highlightColor);
    mark.style.textShadow = p === 'clean' ? '0 1px 4px #000' : p === 'box' ? 'none' : '-1px -1px 0 #000,1px -1px 0 #000,-1px 1px 0 #000,1px 1px 0 #000';
  }
  for (const b of $('capPos').querySelectorAll('button')) b.setAttribute('aria-pressed', String(b.dataset.p === st.position));
  for (const b of $('capHi').querySelectorAll('.sw')) b.setAttribute('aria-pressed', String(+b.dataset.c === st.highlightColor));
  $('capSize').value = st.size;
  $('capSizeV').textContent = Math.round(st.size * 100) + '%';
  $('capCaps').checked = st.uppercase;
  $('capCount').textContent = have ? `(${state.cues.length} captions)` : '';
  updateKeeps();
}
function drawCueList() {
  $('capList').innerHTML = state.cues.map((c, i) =>
    `<div class="cue"><time data-i="${i}" title="Jump here">${fmtT(c.t0)}</time><input data-i="${i}" value="${c.words.map((w) => w.w).join(' ').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')}" aria-label="Caption at ${fmtT(c.t0)}"></div>`).join('');
}
$('capList').addEventListener('change', (e) => {
  const i = +e.target.dataset.i;
  if (!e.target.matches('input')) return;
  const next = editCue(state.cues[i], e.target.value);
  if (next) state.cues[i] = next; else state.cues.splice(i, 1);
  drawCueList();
  drawCaptions();
  schedule(true);
});
$('capList').addEventListener('click', (e) => {
  const t = e.target.closest('time');
  if (!t || !state.meta) return;
  const c = state.cues[+t.dataset.i];
  state.timeS = Math.min(state.meta.durationS - 0.05, (c.t0 + Math.min(300, (c.t1 - c.t0) / 2)) / 1000);
  $('time').value = Math.round((state.timeS / Math.max(0.05, state.meta.durationS - 0.05)) * 1000);
  showView(false);
  schedule(true);
});
$('capPresets').onclick = (e) => { const b = e.target.closest('.preset'); if (b) { state.capStyle.preset = b.dataset.p; drawCaptions(); schedule(true); } };
$('capPos').onclick = (e) => { const b = e.target.closest('button'); if (b) { state.capStyle.position = b.dataset.p; drawCaptions(); schedule(true); } };
$('capHi').onclick = (e) => { const b = e.target.closest('.sw'); if (b) { state.capStyle.highlightColor = +b.dataset.c; drawCaptions(); schedule(true); } };
$('capSize').oninput = (e) => { state.capStyle.size = +e.target.value; drawCaptions(); schedule(); };
$('capCaps').onchange = (e) => { state.capStyle.uppercase = e.target.checked; drawCaptions(); schedule(true); };
$('capOn').onchange = (e) => { state.capOn = e.target.checked; drawCaptions(); schedule(true); };
$('capCancel').onclick = () => state.capAbort?.abort();
$('capGo').onclick = async () => {
  if (!state.file || state.capAbort) return;
  setErr('');
  state.capAbort = new AbortController();
  $('capProg').classList.remove('hidden');
  $('capBar').value = 0;
  drawCaptions();
  const label = { audio: 'Reading the sound…', model: 'Loading the speech model', listen: 'Listening' };
  try {
    const words = await transcribe(state.file, $('capLang').value, {
      signal: state.capAbort.signal, model: state.speechModel,
      onProgress: (stage, pct) => {
        const total = stage === 'audio' ? 0 : stage === 'model' ? pct * 0.1 : 10 + pct * 0.9;
        $('capBar').value = total;
        $('capText').textContent = stage === 'audio' ? label.audio : `${label[stage]} · ${pct}%`;
      },
    });
    state.cues = groupCues(words);
    state.capOn = true;
    $('capHint').textContent = state.cues.length
      ? 'Check the words below; tap a time to see it on the preview.'
      : 'No speech was found in this video.';
    drawCueList();
    if (state.cues.length) $('time').dispatchEvent(new Event('input'));
  } catch (e) {
    if (e.code === 'nomodel') $('capModel').classList.remove('hidden');
    else if (e.name !== 'AbortError') setErr('Captions failed: ' + (e.message || e));
  } finally {
    state.capAbort = null;
    $('capProg').classList.add('hidden');
    drawCaptions();
    schedule(true);
  }
};
$('capModelPick').onclick = () => $('capModelFile').click();
$('capModelFile').onchange = async (e) => {
  const f = e.target.files[0];
  if (!f) return;
  const buf = await f.arrayBuffer();
  const head = new TextDecoder().decode(new Uint8Array(buf, 0, 4));
  if (buf.byteLength < 1e6 || !['lmgg', 'ggml', 'ggjt', 'ggla'].includes(head)) {
    setErr('That file is not a speech model. Choose ggml-tiny-q5_1.bin.');
    return;
  }
  state.speechModel = buf;
  $('capModel').classList.add('hidden');
  $('capGo').click();
};
drawCaptions();

// ---------- background kind
function setKind(k) {
  state.kind = k;
  for (const b of document.querySelectorAll('.seg button')) b.setAttribute('aria-pressed', String(b.dataset.k === k));
  $('optColor').classList.toggle('hidden', k !== 'color');
  $('optImage').classList.toggle('hidden', k !== 'image');
  $('optVideo').classList.toggle('hidden', k !== 'video');
  $('optBlur').classList.toggle('hidden', k !== 'blur');
  drawPlacement();
  schedule(true);
}
document.querySelector('.seg').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  setKind(b.dataset.k);
  if (b.dataset.k === 'image' && !state.image) $('imgFile').click();
  if (b.dataset.k === 'video' && !state.bgVideo) $('vidFile').click();
});
$('pickImg').onclick = () => $('imgFile').click();
$('pickVid').onclick = () => $('vidFile').click();
$('imgFile').onchange = async (e) => {
  const f = e.target.files[0];
  if (!f) return;
  try {
    state.image = await loadImageBitmap(f);
    $('imgName').textContent = f.name;
    setKind('image');
  } catch { setErr('That image could not be opened.'); }
};
$('vidFile').onchange = async (e) => {
  const f = e.target.files[0];
  if (!f) return;
  try {
    state.bgVideo = await videoElement(URL.createObjectURL(f));
    $('vidName').textContent = f.name;
    setKind('video');
  } catch { setErr('That background video could not be opened.'); }
};
const blurLabel = () => ($('blurV').textContent = Math.round(((state.blur - 0.005) / 0.075) * 100) + '%');
$('blur').oninput = (e) => { state.blur = +e.target.value; blurLabel(); schedule(); };
blurLabel();
for (const id of ['smooth', 'soft', 'clean']) $(id).addEventListener('change', () => schedule(true));

// ---------- open video
async function openVideo(file) {
  setErr('');
  if (!('VideoEncoder' in window) || !('VideoDecoder' in window)) {
    setErr('This browser has no WebCodecs support. Use a recent Chrome, Edge or Safari.');
    return;
  }
  $('busy').style.display = 'block';
  try {
    const meta = await demux(file);
    if (state.url) URL.revokeObjectURL(state.url);
    state.file = file;
    state.meta = meta;
    state.url = URL.createObjectURL(file);
    state.videoEl = await videoElement(state.url);
    $('orig').src = state.url;
    $('drop').classList.add('hidden');
    $('scrub').classList.remove('hidden');
    $('meta').textContent = `${file.name} · ${summary(meta)}`;
    state.cues = [];
    state.person = { scale: 1, x: 0, y: 0 };
    drawPlacement();
    drawCueList();
    drawCaptions();
    drawShapes();
    $('export').disabled = false;
    $('result').classList.add('hidden');
    state.timeS = meta.durationS * 0.2;
    $('time').value = 200;
    showView(false);
    schedule(true);
  } catch (e) {
    setErr(e.message || String(e));
  } finally {
    $('busy').style.display = 'none';
  }
}
$('file').onchange = (e) => e.target.files[0] && openVideo(e.target.files[0]);
$('another').onclick = () => $('file').click();
const drop = $('drop');
drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
drop.addEventListener('dragleave', () => drop.classList.remove('over'));
drop.addEventListener('drop', (e) => {
  e.preventDefault();
  drop.classList.remove('over');
  const f = e.dataTransfer.files[0];
  if (f) openVideo(f);
});

// ---------- preview
function showView(original) {
  state.showOriginal = original;
  $('vRes').setAttribute('aria-pressed', String(!original));
  $('vOrig').setAttribute('aria-pressed', String(original));
  $('out').classList.toggle('hidden', original);
  $('orig').classList.toggle('hidden', !original);
  if (original) $('orig').currentTime = state.timeS;
}
$('vRes').onclick = () => showView(false);
$('vOrig').onclick = () => showView(true);
$('time').oninput = (e) => {
  if (!state.meta) return;
  state.timeS = (+e.target.value / 1000) * Math.max(0, state.meta.durationS - 0.05);
  if (state.showOriginal) $('orig').currentTime = state.timeS;
  schedule();
};

let timer;
function schedule(now = false) {
  if (!state.meta) return;
  clearTimeout(timer);
  timer = setTimeout(render, now ? 0 : 200);
}
async function render() {
  if (state.rendering) { state.again = true; return; }
  state.rendering = true;
  $('busy').style.display = 'block';
  do {
    state.again = false;
    try {
      await renderPreview({
        videoEl: state.videoEl, canvas: $('out'), timeS: state.timeS, bg: background(),
        settings: settings(), landscape: state.meta.displayWidth > state.meta.displayHeight, frame: frame(),
        captions: captions(), outline: outline(),
      });
      if (!state.showOriginal) $('out').classList.remove('hidden');
      setErr('');
    } catch (e) {
      console.error(e);
      setErr('Preview failed: ' + (e.message || e));
    }
  } while (state.again);
  state.rendering = false;
  $('busy').style.display = 'none';
}


// ---------- outline around the speaker
const OUTLINE_SW = [0xffffffff, 0xff000000, 0xfff59e0b, 0xffec4899, 0xff2dd4bf, 0xff0047bb, 0xffef4444, 0xff22c55e];
state.outline = { on: false, argb: 0xffffffff, width: 0.012, glow: false };
const outline = () => (state.outline.on ? { argb: state.outline.argb, width: state.outline.width, glow: state.outline.glow } : null);
function drawOutline() {
  const o = state.outline;
  $('olOpts').classList.toggle('hidden', !o.on);
  $('olSw').innerHTML = OUTLINE_SW.map((c) =>
    `<button class="sw" style="background:${hex(c)}" data-c="${c}" aria-label="Outline colour ${hex(c)}" aria-pressed="${c === o.argb}"></button>`).join('');
  for (const b of $('olWidth').children) b.setAttribute('aria-pressed', String(+b.dataset.w === o.width));
  for (const b of $('olLook').children) b.setAttribute('aria-pressed', String(!!+b.dataset.g === o.glow));
}
$('olOn').onchange = (e) => { state.outline.on = e.target.checked; drawOutline(); schedule(true); };
$('olSw').onclick = (e) => { const b = e.target.closest('.sw'); if (!b) return; state.outline.argb = +b.dataset.c >>> 0; drawOutline(); schedule(true); };
$('olCustom').oninput = (e) => { state.outline.argb = (0xff000000 | parseInt(e.target.value.slice(1), 16)) >>> 0; drawOutline(); schedule(); };
$('olWidth').onclick = (e) => { const b = e.target.closest('button'); if (!b) return; state.outline.width = +b.dataset.w; drawOutline(); schedule(true); };
$('olLook').onclick = (e) => { const b = e.target.closest('button'); if (!b) return; state.outline.glow = !!+b.dataset.g; drawOutline(); schedule(true); };
drawOutline();

// ---------- intro & outro clips, animations
state.before = []; state.after = []; state.into = 'fade';
let clipTarget = 'before';
const sequence = () => ({
  before: state.before, after: state.after, into: state.into,
  fadeIn: $('fadeIn').checked, fadeOut: $('fadeOut').checked, transitionS: +$('trLen').value,
});
const trOptions = (sel) => TRANSITIONS.map(([id, label]) => `<option value="${id}"${id === sel ? ' selected' : ''}>${label}</option>`).join('');
const secs = (x) => (x >= 10 ? Math.round(x) : Math.round(x * 10) / 10) + ' s';
function drawClips() {
  for (const [key, el] of [['before', 'listBefore'], ['after', 'listAfter']]) {
    $(el).innerHTML = state[key].map((c, i) => `
      <div class="clip" data-list="${key}" data-i="${i}">
        <img class="thumb" src="${c.thumb}" alt="">
        <div class="opts">
          <div class="name">${c.kind === 'video' ? '🎬' : '🖼'} ${c.name.replace(/[<>&"]/g, '')} · ${secs(c.kind === 'video' ? Math.min(c.element.duration, c.maxS) : c.durationS)}</div>
          <select data-f="transition" aria-label="Animation into this part">${trOptions(c.transition)}</select>
          <select data-f="fit" aria-label="How it fits"><option value="0"${c.fit ? '' : ' selected'}>Fill frame</option><option value="1"${c.fit ? ' selected' : ''}>Whole picture</option></select>
          ${c.kind === 'image' ? `
          <select data-f="durationS" aria-label="Show for">${[2, 3, 4, 5, 7, 10].map((d) => `<option value="${d}"${d === c.durationS ? ' selected' : ''}>${d} seconds</option>`).join('')}</select>
          <select data-f="motion" aria-label="Movement"><option value="none"${c.motion === 'none' ? ' selected' : ''}>Still</option><option value="in"${c.motion === 'in' ? ' selected' : ''}>Slow zoom in</option><option value="out"${c.motion === 'out' ? ' selected' : ''}>Slow zoom out</option></select>` : ''}
        </div>
        <button class="btn" data-del aria-label="Remove">✕</button>
      </div>`).join('');
  }
  $('trInto').innerHTML = TRANSITIONS.map(([id, label]) => `<button data-t="${id}" aria-pressed="${id === state.into}">${label}</button>`).join('');
  const extra = clipsDuration(state.before) + clipsDuration(state.after);
  $('trInto').previousElementSibling.textContent = state.before.length ? 'Animation into your video' : 'Animation into your video (used after an intro)';
  if (state.meta) $('keeps').dataset.extra = extra ? ` Intro and outro add ${secs(extra)}.` : '';
}
for (const el of ['listBefore', 'listAfter']) {
  $(el).addEventListener('change', (e) => {
    const row = e.target.closest('.clip'), f = e.target.dataset.f;
    if (!row || !f) return;
    const c = state[row.dataset.list][+row.dataset.i];
    c[f] = f === 'fit' ? e.target.value === '1' : f === 'durationS' ? +e.target.value : e.target.value;
    drawClips();
  });
  $(el).addEventListener('click', (e) => {
    const row = e.target.closest('.clip');
    if (!row || !e.target.closest('[data-del]')) return;
    const [c] = state[row.dataset.list].splice(+row.dataset.i, 1);
    if (c.element) { c.element.remove(); URL.revokeObjectURL(c.element.src); }
    drawClips();
  });
}
$('addBefore').onclick = () => { clipTarget = 'before'; $('clipFile').click(); };
$('addAfter').onclick = () => { clipTarget = 'after'; $('clipFile').click(); };
$('trInto').onclick = (e) => { const b = e.target.closest('button'); if (!b) return; state.into = b.dataset.t; drawClips(); };
$('trLen').oninput = (e) => ($('trLenV').textContent = (+e.target.value).toFixed(1) + ' s');
async function addClip(f, where = clipTarget) {
  setErr('');
  try {
    let clip;
    if (f.type.startsWith('video')) {
      const element = await videoElement(URL.createObjectURL(f));
      const c = document.createElement('canvas');
      c.width = 112; c.height = Math.max(2, Math.round(112 * element.videoHeight / Math.max(1, element.videoWidth)));
      c.getContext('2d').drawImage(element, 0, 0, c.width, c.height);
      clip = { kind: 'video', element, name: f.name, fit: false, transition: 'fade', maxS: 60, thumb: c.toDataURL('image/jpeg', 0.7) };
    } else {
      const bitmap = await loadImageBitmap(f);
      const c = document.createElement('canvas');
      c.width = 112; c.height = Math.max(2, Math.round(112 * bitmap.height / bitmap.width));
      c.getContext('2d').drawImage(bitmap, 0, 0, c.width, c.height);
      clip = { kind: 'image', bitmap, name: f.name, fit: false, transition: 'fade', durationS: 3, motion: 'in', thumb: c.toDataURL('image/jpeg', 0.7) };
    }
    state[where].push(clip);
    drawClips();
    return clip;
  } catch (e) {
    console.error(e);
    setErr('Could not open ' + f.name + ': ' + (e.message || e));
  }
}
$('clipFile').onchange = async (e) => {
  const f = e.target.files[0];
  e.target.value = '';
  if (f) await addClip(f);
};
drawClips();

// ---------- export
$('export').onclick = async () => {
  if (!state.meta) return;
  setErr('');
  $('export').disabled = true;
  $('prog').classList.remove('hidden');
  $('result').classList.add('hidden');
  $('pbar').value = 0;
  $('ptext').textContent = 'Starting…';
  state.abort = new AbortController();
  try {
    const r = await exportVideo({
      meta: state.meta, bg: background(), settings: settings(), signal: state.abort.signal, frame: frame(),
      sound: sound(), file: state.file, captions: captions(), outline: outline(), sequence: sequence(),
      onProgress: ({ fraction, frames, total, fps, stage }) => {
        $('pbar').value = fraction;
        if (stage === 'clips') { $('ptext').textContent = frames ? 'Adding the outro…' : 'Adding the intro…'; return; }
        const left = fps > 0 ? Math.round((total - frames) / fps) : 0;
        $('ptext').textContent = `${Math.round(fraction * 100)}% · frame ${frames} of ${total} · ${fps.toFixed(1)} fps · about ${Math.floor(left / 60)}m ${left % 60}s left`;
      },
    });
    state.result = r;
    if (state.resultUrl) URL.revokeObjectURL(state.resultUrl);
    state.resultUrl = URL.createObjectURL(r.blob);
    $('resVid').src = state.resultUrl;
    $('resText').textContent = `${(r.blob.size / 1e6).toFixed(1)} MB · ${r.frames} frames · encoder ${r.encoder}` +
      (r.warnings.length ? ' · ' + r.warnings.join(' ') : '');
    $('result').classList.remove('hidden');
    window.__hbrLastExport = r; // used by automated tests
  } catch (e) {
    if (e.name !== 'AbortError') { console.error(e); setErr('Export failed: ' + (e.message || e)); }
  } finally {
    $('prog').classList.add('hidden');
    $('export').disabled = false;
  }
};
$('cancel').onclick = () => state.abort?.abort();

// Saving: inside Claude the page asks the viewer's permission through the
// downloads capability; standalone it is a normal download.
$('save').onclick = async () => {
  const r = state.result;
  if (!r) return;
  const name = (state.file?.name.replace(/\.[^.]+$/, '') || 'video') + '-background.mp4';
  try {
    const dl = window.claude?.use ? await window.claude.use('downloads') : null;
    if (dl) {
      await dl.save({ filename: name, data: r.blob });
      return;
    }
  } catch (e) {
    console.warn('downloads capability failed', e);
  }
  const a = document.createElement('a');
  a.href = state.resultUrl;
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
};

// Offline: cache the app when served standalone (not inside Claude's frame).
if ('serviceWorker' in navigator && location.protocol.startsWith('http') && window.top === window) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}

window.__hbr = { openVideo, addClip, state, schedule, drawShapes, drawPlacement, drawCaptions, drawCueList, groupCues }; // test hook
