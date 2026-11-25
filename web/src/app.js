import { demux, summary, renderPreview, exportVideo, loadImageBitmap, videoElement } from './pipeline.js';

const $ = (id) => document.getElementById(id);
const SWATCHES = [0xff00b140, 0xff0047bb, 0xffffffff, 0xff000000, 0xff808080, 0xff2dd4bf, 0xfff59e0b, 0xffec4899];

const state = {
  file: null, url: null, meta: null, videoEl: null,
  kind: 'color', argb: SWATCHES[0], image: null, bgVideo: null, blur: 0.03,
  showOriginal: false, timeS: 0, rendering: false, again: false, abort: null, result: null,
  aspect: 'original', fit: false, placement: { scale: 1, panX: 0, panY: 0, fill: 0xff000000 },
};
const SHAPES = [['original', 'Original'], ['9:16', '9:16'], ['1:1', '1:1'], ['4:5', '4:5'], ['16:9', '16:9']];
const frame = () => ({ aspect: state.aspect, fit: state.fit });
const sound = () => ({ music: state.music, musicVolume: +$('mvol').value, voiceVolume: +$('vvol').value, duck: $('duck').checked });

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
  $('out').classList.toggle('movable', !!movable);
  $('scale').value = state.placement.scale;
  $('scaleV').textContent = Math.round(state.placement.scale * 100) + '%';
  $('fillRow').classList.toggle('hidden', state.placement.scale >= 1);
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
  $('vvolV').textContent = Math.round(+$('vvol').value * 100) + '%';
  updateKeeps();
}
$('musicPick').onclick = () => $('musicFile').click();
$('musicFile').onchange = (e) => { const f = e.target.files[0]; if (f) { state.music = f; drawSound(); } };
$('musicDel').onclick = () => { state.music = null; $('musicFile').value = ''; drawSound(); };
$('mvol').oninput = drawSound;
$('vvol').oninput = drawSound;

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
      sound: sound(), file: state.file,
      onProgress: ({ fraction, frames, total, fps }) => {
        $('pbar').value = fraction;
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

window.__hbr = { openVideo, state, schedule, drawShapes, drawPlacement }; // test hook
