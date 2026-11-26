'use strict';

/* ------------------------------------------------------------------ */
/* 实时换脸控制台                                                      */
/* ------------------------------------------------------------------ */

const $ = (id) => document.getElementById(id);

const stageCanvas = $('stageCanvas');
const ctx = stageCanvas.getContext('2d', { alpha: false });
const video = $('cam');
const stageOverlay = $('stageOverlay');
const overlaySpinner = $('overlaySpinner');
const overlayMark = $('overlayMark');
const overlayTitle = $('overlayTitle');
const overlayText = $('overlayText');
const overlayStartBtn = $('overlayStartBtn');
const camLabel = $('camLabel');
const dropVeil = $('dropVeil');
const startBtn = $('startBtn');
const outputBtn = $('outputBtn');
const liveBadge = $('liveBadge');
const stageSub = $('stageSub');
const frameHint = $('frameHint');
const fileInput = $('fileInput');
const uploadTile = $('uploadTile');
// 这两个节点会随 uploadTile 一起被移出/重挂，提前缓存引用
const uploadTextEl = $('uploadText');
const uploadHintEl = $('uploadHint');
const photoGrid = $('photoGrid');
const photoCount = $('photoCount');
const delayRange = $('delayRange');
const delayVal = $('delayVal');
const qualityRange = $('qualityRange');
const qualityVal = $('qualityVal');
const detectSelect = $('detectSelect');
const detectVal = $('detectVal');
const delayBadge = $('delayBadge');
const statusPill = $('statusPill');
const statusText = $('statusText');
const statusDot = $('statusDot');
const toastWrap = $('toastWrap');

const S = {
  server: null,
  ready: false,
  running: false,
  stream: null,
  inFlight: 0,
  encoding: false,
  delayMs: Number(localStorage.getItem('lf_delay') ?? 0),
  quality: Number(localStorage.getItem('lf_quality') ?? 72) / 100,
  photos: [],
  active: null,
  photoSig: '',
  sessionId: (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2)),
  lastDrawnTs: -1,
  dropped: 0,      // 服务端返回 204 的帧
  skipped: 0,      // 两个处理槽都忙时跳过的摄像头帧
  procLat: [],
  dispLat: [],
  shown: [],
  frameW: 1280,
  frameH: 720,
  outputConnected: false,
  outputLastPing: 0,
  lastTick: 0,
  connected: false,
};

const sendCanvas = (typeof OffscreenCanvas !== 'undefined')
  ? new OffscreenCanvas(1280, 720)
  : document.createElement('canvas');
const sctx = sendCanvas.getContext('2d');
const bc = ('BroadcastChannel' in window) ? new BroadcastChannel('dlc-faceswap') : null;

/* ------------------------------------------------------------------ */
/* 工具                                                                */
/* ------------------------------------------------------------------ */
function toast(msg, kind = '') {
  const el = document.createElement('div');
  el.className = 'toast ' + kind;
  el.textContent = msg;
  toastWrap.appendChild(el);
  setTimeout(() => {
    el.style.transition = 'opacity .25s, transform .25s';
    el.style.opacity = '0';
    el.style.transform = 'translateY(6px)';
    setTimeout(() => el.remove(), 300);
  }, 3200);
}

function fmtMs(v) {
  if (v == null || !isFinite(v)) return '–';
  return (v >= 100 ? Math.round(v) : Math.round(v * 10) / 10) + ' ms';
}

function p50(arr) {
  if (!arr.length) return null;
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.floor((s.length - 1) * 0.5)];
}

function humanDuration(sec) {
  sec = Math.max(0, Math.round(sec));
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

/* ------------------------------------------------------------------ */
/* 服务状态                                                            */
/* ------------------------------------------------------------------ */
const STATUS_TEXT = {
  starting: '服务启动中…',
  'loading-analyser': '加载人脸模型…',
  'warming-detector': '预热检测模型…',
  'loading-swapper': '加载换脸模型…',
  'loading-photos': '载入照片库…',
  'warming-swapper': '首次编译换脸模型…',
  ready: '就绪',
  error: '启动失败',
};

async function refreshState() {
  try {
    const r = await fetch('/api/state', { cache: 'no-store' });
    const j = await r.json();
    S.server = j;
    S.connected = true;
    applyState(j);
  } catch (err) {
    S.connected = false;
    S.ready = false;
    statusPill.classList.remove('ready', 'busy');
    statusPill.classList.add('error');
    statusText.textContent = '连接断开';
    if (!S.running) updateOverlay();
  }
}

function applyState(j) {
  const ready = !!j.ready && j.status === 'ready';
  S.ready = ready;

  statusPill.classList.remove('ready', 'error', 'busy');
  if (j.status === 'ready') {
    statusPill.classList.add('ready');
  } else if (j.status === 'error') {
    statusPill.classList.add('error');
    statusText.textContent = '启动失败';
  } else {
    statusPill.classList.add('busy');
    statusText.textContent = STATUS_TEXT[j.status] || j.message || '启动中…';
  }
  if (j.status === 'ready') {
    statusText.textContent = S.running ? '直播中' : '就绪';
  }

  // 照片
  S.photos = j.photos || [];
  S.active = j.active || null;
  const sig = S.photos.map((p) => p.id).join(',') + '|' + S.active;
  if (sig !== S.photoSig) {
    S.photoSig = sig;
    renderPhotos();
  }
  photoCount.textContent = `${S.photos.length} 张`;
  const activePhoto = S.photos.find((p) => p.id === S.active);
  $('kPhoto').textContent = activePhoto ? activePhoto.name : '未选择';

  // 设置
  if (j.settings) {
    if (document.activeElement !== detectSelect) {
      detectSelect.value = String(j.settings.detect_interval || 3);
    }
    updateDetectLabel();
  }

  // 统计
  const st = j.stats || {};
  $('sAccel').textContent = j.coreml ? 'CoreML / ANE' : 'CPU（未启用 CoreML）';
  $('sServerP50').textContent = st.server_p50_ms != null ? fmtMs(st.server_p50_ms) : '–';
  const summary = [j.coreml ? 'CoreML' : 'CPU'];
  if (st.server_p50_ms != null) summary.push(`P50 ${Math.round(st.server_p50_ms)}ms`);
  $('sSummary').textContent = summary.join(' · ');
  const bd = [];
  if (st.avg_detect_ms != null) bd.push(`检 ${Math.round(st.avg_detect_ms)}`);
  if (st.avg_swap_ms != null) bd.push(`换 ${Math.round(st.avg_swap_ms)}`);
  if (st.avg_encode_ms != null) bd.push(`编 ${Math.round(st.avg_encode_ms)}`);
  $('sBreakdown').textContent = bd.length ? bd.join(' · ') + ' ms' : '–';

  const warm = j.warmup || {};
  if (warm.swap_warming) {
    $('sWarm').textContent = '编译中…';
  } else if (warm.swap_ms != null) {
    $('sWarm').textContent = `检测 ${Math.round(warm.detect_ms || 0)} / 换脸 ${Math.round(warm.swap_ms)} ms`;
  } else {
    $('sWarm').textContent = '待上传照片';
  }
  $('sIdle').textContent = humanDuration(j.idle_remaining_s || 0);

  startBtn.disabled = !S.ready && !S.running;
  updateOverlay();

  if (j.status === 'error') {
    overlaySpinner.classList.add('hidden');
    overlayTitle.textContent = '服务启动失败';
    overlayText.textContent = j.error || j.message || '请查看终端日志';
  }
}

function setOverlayArt(loading, showMark) {
  overlaySpinner.classList.toggle('hidden', !loading);
  overlayMark.classList.toggle('hidden', !showMark);
}

function updateOverlay() {
  if (S.running) {
    stageOverlay.classList.add('hidden');
    return;
  }
  stageOverlay.classList.remove('hidden');
  const j = S.server;
  const canStart = !!(S.connected && j && j.status === 'ready');
  overlayStartBtn.hidden = !canStart;
  overlayStartBtn.disabled = !canStart;

  if (!S.connected) {
    setOverlayArt(true, false);
    overlayTitle.textContent = '正在连接服务…';
    overlayText.textContent = '如果会话没有运行，请双击 LiveFace.app 或 start.command';
    return;
  }
  if (!j) return;

  if (j.status === 'error') {
    setOverlayArt(false, false);
    overlayTitle.textContent = '服务启动失败';
    overlayText.textContent = j.error || j.message || '';
    return;
  }
  if (!S.ready) {
    setOverlayArt(true, false);
    overlayTitle.textContent = j.message || '启动中…';
    overlayText.textContent = j.status === 'warming-swapper'
      ? '正在用 CoreML 编译换脸模型，通常 1–3 分钟。编译结果会被系统缓存，下次启动很快。'
      : '首次启动需要编译 CoreML 模型，请耐心等待。';
    return;
  }
  setOverlayArt(false, true);
  overlayTitle.textContent = '准备就绪';
  overlayText.textContent = S.photos.length
    ? '点击「开始直播」并允许浏览器访问摄像头'
    : '先上传一张人像照片，然后点击「开始直播」';
}

/* ------------------------------------------------------------------ */
/* 照片库                                                              */
/* ------------------------------------------------------------------ */
function renderPhotos() {
  photoGrid.innerHTML = '';
  const empty = S.photos.length === 0;
  photoGrid.classList.toggle('empty', empty);
  uploadTile.classList.toggle('empty', empty);
  if (!uploadTile.classList.contains('loading')) {
    uploadTextEl.textContent = empty ? '拖入或点击上传人像照片' : '添加照片';
    uploadHintEl.textContent = empty ? 'JPG / PNG / WEBP · 建议清晰正脸' : '可多选';
  }

  S.photos.forEach((p, i) => {
    const el = document.createElement('div');
    el.className = 'photo-item' + (p.id === S.active ? ' active' : '');
    el.title = p.name;
    const img = document.createElement('img');
    img.src = p.thumb;
    img.alt = p.name;
    img.loading = 'lazy';
    const idx = document.createElement('span');
    idx.className = 'idx';
    idx.textContent = String(i + 1);
    const del = document.createElement('button');
    del.className = 'del';
    del.textContent = '×';
    del.title = '删除';
    del.addEventListener('click', (ev) => {
      ev.stopPropagation();
      deletePhoto(p.id);
    });
    el.appendChild(img);
    el.appendChild(idx);
    el.appendChild(del);
    el.addEventListener('click', () => selectPhoto(p.id));
    photoGrid.appendChild(el);
  });
  photoGrid.appendChild(uploadTile);
}

async function selectPhoto(id) {
  try {
    const r = await fetch('/api/select', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id }),
    });
    if (!r.ok) {
      toast('切换失败', 'error');
      return;
    }
    S.active = id;
    renderPhotos();
    const p = S.photos.find((x) => x.id === id);
    $('kPhoto').textContent = p ? p.name : '未选择';
    toast('已切换：' + (p ? p.name : id), 'ok');
  } catch (e) {
    toast('切换失败：' + e.message, 'error');
  }
}

async function deletePhoto(id) {
  if (!confirm('删除这张照片？')) return;
  try {
    await fetch('/api/delete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id }),
    });
    await refreshState();
  } catch (e) {
    toast('删除失败：' + e.message, 'error');
  }
}

async function uploadFiles(files) {
  const imgs = [...files].filter((f) => f.type && f.type.startsWith('image/'));
  if (!imgs.length) {
    toast('请选择或拖入图片文件', 'error');
    return;
  }
  uploadTile.classList.add('loading');
  uploadTextEl.textContent = '分析人脸中…';
  uploadHintEl.textContent = '请稍候';

  const fd = new FormData();
  imgs.forEach((f) => fd.append('photos', f, f.name));
  try {
    const r = await fetch('/api/upload', { method: 'POST', body: fd });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.ok) {
      toast(j.error || `上传失败（HTTP ${r.status}）`, 'error');
    } else {
      if (j.added && j.added.length) toast(`已添加 ${j.added.length} 张照片`, 'ok');
      (j.errors || []).forEach((e) => toast(`${e.name}：${e.error}`, 'error'));
    }
    await refreshState();
  } catch (e) {
    toast('上传失败：' + e.message, 'error');
  } finally {
    uploadTile.classList.remove('loading');
    fileInput.value = '';
    renderPhotos();
  }
}

fileInput.addEventListener('change', () => uploadFiles(fileInput.files));

/* 拖拽上传：拖到页面任意位置 */
let dragDepth = 0;
window.addEventListener('dragenter', (e) => {
  if (!e.dataTransfer) return;
  e.preventDefault();
  dragDepth += 1;
  dropVeil.classList.add('show');
});
window.addEventListener('dragover', (e) => {
  if (!e.dataTransfer) return;
  e.preventDefault();
  e.dataTransfer.dropEffect = 'copy';
});
window.addEventListener('dragleave', () => {
  dragDepth = Math.max(0, dragDepth - 1);
  if (dragDepth === 0) dropVeil.classList.remove('show');
});
window.addEventListener('drop', (e) => {
  if (!e.dataTransfer) return;
  e.preventDefault();
  dragDepth = 0;
  dropVeil.classList.remove('show');
  if (e.dataTransfer.files && e.dataTransfer.files.length) {
    uploadFiles(e.dataTransfer.files);
  }
});

/* ------------------------------------------------------------------ */
/* 设置                                                                */
/* ------------------------------------------------------------------ */
function initSettings() {
  delayRange.value = String(S.delayMs);
  updateDelayLabel();
  qualityRange.value = String(Math.round(S.quality * 100));
  updateQualityLabel();
  updateDetectLabel();
}

function updateDelayLabel() {
  delayVal.textContent = `${S.delayMs} ms`;
  $('kDelay').textContent = `${S.delayMs} ms`;
  if (S.delayMs === 0) {
    delayBadge.textContent = '低延迟';
    delayBadge.style.color = '';
  } else {
    delayBadge.textContent = `同步 +${S.delayMs} ms`;
    delayBadge.style.color = 'var(--accent-2)';
  }
}

delayRange.addEventListener('input', () => {
  S.delayMs = Number(delayRange.value);
  localStorage.setItem('lf_delay', String(S.delayMs));
  updateDelayLabel();
});

qualityRange.addEventListener('input', () => {
  const pct = Number(qualityRange.value);
  S.quality = pct / 100;
  localStorage.setItem('lf_quality', String(pct));
  updateQualityLabel();
});

function updateQualityLabel() {
  qualityVal.textContent = `${Math.round(S.quality * 100)}%`;
}

function updateDetectLabel() {
  const v = Number(detectSelect.value);
  detectVal.textContent = v === 1 ? '每帧检测' : `每 ${v} 帧`;
}

detectSelect.addEventListener('change', async () => {
  updateDetectLabel();
  try {
    await fetch('/api/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ detect_interval: Number(detectSelect.value) }),
    });
  } catch (e) {
    toast('设置保存失败', 'error');
  }
});

/* ------------------------------------------------------------------ */
/* 摄像头 & 帧发送                                                     */
/* ------------------------------------------------------------------ */
async function startCamera() {
  if (!S.ready) {
    toast('服务还未就绪，请稍候', 'error');
    return;
  }
  if (S.running) {
    stopCamera();
    return;
  }
  try {
    S.stream = await navigator.mediaDevices.getUserMedia({
      video: {
        width: { ideal: 1280 },
        height: { ideal: 720 },
        frameRate: { ideal: 30, max: 30 },
      },
      audio: false,
    });
  } catch (e) {
    toast('摄像头打开失败：' + e.message, 'error');
    return;
  }

  video.srcObject = S.stream;
  try {
    await video.play();
  } catch (e) {
    toast('视频播放失败：' + e.message, 'error');
  }
  await new Promise((resolve) => {
    if (video.videoWidth) return resolve();
    video.addEventListener('loadedmetadata', resolve, { once: true });
    setTimeout(resolve, 1500);
  });

  const vw = video.videoWidth || 1280;
  const vh = video.videoHeight || 720;
  const scale = Math.min(1, 1280 / vw);
  S.frameW = Math.max(2, Math.round(vw * scale));
  S.frameH = Math.max(2, Math.round(vh * scale));

  sendCanvas.width = S.frameW;
  sendCanvas.height = S.frameH;
  stageCanvas.width = S.frameW;
  stageCanvas.height = S.frameH;
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, stageCanvas.width, stageCanvas.height);

  S.running = true;
  S.lastDrawnTs = -1;
  S.dropped = 0;
  S.skipped = 0;
  S.procLat = [];
  S.dispLat = [];
  S.shown = [];

  video.classList.add('show');
  camLabel.classList.add('show');
  startBtn.textContent = '停止直播';
  startBtn.classList.add('stop');
  liveBadge.textContent = 'LIVE';
  liveBadge.classList.add('on');
  stageSub.textContent = `${S.frameW}×${S.frameH} · 实时换脸中`;
  frameHint.textContent = '1–9 切换人物 · 输出窗口供 OBS 采集';
  stageOverlay.classList.add('hidden');

  if ('requestVideoFrameCallback' in video) {
    video.requestVideoFrameCallback(onVideoFrame);
  }
  if (bc) bc.postMessage({ type: 'signal', state: 'started' });
  toast('直播已开始', 'ok');
}

function stopCamera() {
  S.running = false;
  if (S.stream) {
    S.stream.getTracks().forEach((t) => t.stop());
    S.stream = null;
  }
  video.srcObject = null;
  video.classList.remove('show');
  camLabel.classList.remove('show');
  startBtn.textContent = '开始直播';
  startBtn.classList.remove('stop');
  liveBadge.textContent = '待机';
  liveBadge.classList.remove('on');
  stageSub.textContent = '摄像头未开启';
  frameHint.textContent = '点击右上角「开始直播」并允许摄像头';
  updateOverlay();
  if (bc) bc.postMessage({ type: 'signal', state: 'stopped' });
}

function onVideoFrame() {
  if (!S.running) return;
  S.lastTick = performance.now();
  // 两个槽都在处理时，这一拍直接放弃（保证延迟不堆积）
  if (S.inFlight >= 2) S.skipped++;
  maybeSend();
  video.requestVideoFrameCallback(onVideoFrame);
}

function maybeSend() {
  if (!S.running || !S.ready) return;
  if (S.inFlight >= 2 || S.encoding) return;
  S.encoding = true;
  // sendFrame 只负责编码 + 把请求发出去，不等待响应；
  // 这样第二个 in-flight 名额能立刻用上（服务端也是 2 并发）。
  sendFrame()
    .catch(() => {})
    .finally(() => { S.encoding = false; });
}

async function encodeJpeg() {
  if (typeof sendCanvas.convertToBlob === 'function') {
    return sendCanvas.convertToBlob({ type: 'image/jpeg', quality: S.quality });
  }
  return new Promise((resolve) => sendCanvas.toBlob(resolve, 'image/jpeg', S.quality));
}

async function sendFrame() {
  const ts = performance.now();

  sctx.drawImage(video, 0, 0, S.frameW, S.frameH);
  let blob;
  try {
    blob = await encodeJpeg();
  } catch (e) {
    return;
  }
  if (!blob) return;

  const jpegBuf = await blob.arrayBuffer();
  const packet = new ArrayBuffer(8 + jpegBuf.byteLength);
  new DataView(packet).setFloat64(0, ts, true); // 小端 float64
  new Uint8Array(packet, 8).set(new Uint8Array(jpegBuf));

  S.inFlight++;
  // 不 await：让 maybeSend 立即可以发下一帧（最多 2 帧在途）
  sendPacket(packet, ts).finally(() => { S.inFlight--; });
}

async function sendPacket(packet, ts) {
  try {
    const res = await fetch(`/api/frame?s=${encodeURIComponent(S.sessionId)}`, {
      method: 'POST',
      body: packet,
      cache: 'no-store',
    });

    if (res.status === 204) {
      S.dropped++; // 服务端积压，主动丢的旧帧
      return;
    }
    if (!res.ok) {
      if (res.status === 503) {
        S.ready = false;
        refreshState();
      }
      return;
    }

    const arrived = performance.now();
    S.procLat.push(arrived - ts);
    if (S.procLat.length > 60) S.procLat.shift();

    const jpeg = await res.arrayBuffer();
    const echoed = parseFloat(res.headers.get('X-Capture-Ts') || '');
    const capture = Number.isFinite(echoed) ? echoed : ts;
    await handleFrame(jpeg, capture);
  } catch (e) {
    // 连接失败：状态轮询会负责把 UI 切到「连接断开」
  }
}

async function handleFrame(jpegBuf, captureTs) {
  let bmp;
  try {
    bmp = await createImageBitmap(new Blob([jpegBuf], { type: 'image/jpeg' }));
  } catch (e) {
    return;
  }
  const target = captureTs + S.delayMs;
  const now = performance.now();
  const wait = target - now;

  if (wait <= 0) {
    drawFrame(bmp, captureTs, jpegBuf);
  } else {
    setTimeout(() => drawFrame(bmp, captureTs, jpegBuf), Math.min(wait, 2000));
  }
}

function drawFrame(bmp, captureTs, jpegBuf) {
  if (!S.running) {
    bmp.close && bmp.close();
    return;
  }
  // 乱序/过期帧：已经有更新的帧上屏了，直接丢掉
  if (captureTs <= S.lastDrawnTs) {
    bmp.close && bmp.close();
    return;
  }
  S.lastDrawnTs = captureTs;

  ctx.drawImage(bmp, 0, 0, stageCanvas.width, stageCanvas.height);
  bmp.close && bmp.close();

  const now = performance.now();
  S.shown.push(now);
  S.dispLat.push(now - captureTs);
  if (S.dispLat.length > 90) S.dispLat.shift();

  // 同步给输出窗口（复制 ArrayBuffer，不 transfer）
  if (S.outputConnected && bc) {
    try {
      bc.postMessage({ type: 'frame', buf: jpegBuf });
    } catch (e) { /* ignore */ }
  }
}

/* 后台标签页兜底：rVFC 可能被暂停，定时器仍会以低频触发 */
setInterval(() => {
  if (!S.running) return;
  if (performance.now() - S.lastTick > 250) {
    S.lastTick = performance.now();
    maybeSend();
  }
}, 300);

/* ------------------------------------------------------------------ */
/* 输出窗口                                                            */
/* ------------------------------------------------------------------ */
outputBtn.addEventListener('click', () => {
  const w = window.open(
    '/output',
    'dlcOutput',
    'width=1280,height=720,menubar=no,toolbar=no,location=no,status=no'
  );
  if (!w) {
    toast('弹窗被拦截，请允许本站弹出窗口', 'error');
  } else {
    w.focus();
  }
});

if (bc) {
  bc.addEventListener('message', (ev) => {
    const m = ev.data || {};
    if (m.type === 'hello' || m.type === 'ping') {
      S.outputConnected = true;
      S.outputLastPing = performance.now();
    } else if (m.type === 'bye') {
      S.outputConnected = false;
    }
  });
}
setInterval(() => {
  if (S.outputConnected && performance.now() - S.outputLastPing > 3500) {
    S.outputConnected = false;
  }
}, 1000);

/* ------------------------------------------------------------------ */
/* 指标面板                                                            */
/* ------------------------------------------------------------------ */
setInterval(() => {
  const now = performance.now();
  S.shown = S.shown.filter((t) => now - t < 2000);
  const fps = S.shown.length / 2;
  $('mFps').textContent = S.running ? fps.toFixed(1) : '–';

  const lat = p50(S.procLat.slice(-30));
  $('mLat').textContent = lat == null ? '–' : Math.round(lat);

  const disp = p50(S.dispLat.slice(-30));
  $('kLatency').textContent = disp == null ? '–' : fmtMs(disp);

  $('mDrop').textContent = String(S.dropped + S.skipped);
}, 500);

/* ------------------------------------------------------------------ */
/* 键盘                                                                */
/* ------------------------------------------------------------------ */
document.addEventListener('keydown', (e) => {
  const tag = (e.target && e.target.tagName) || '';
  if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return;

  if (e.code === 'Space') {
    e.preventDefault();
    if (S.ready) startCamera();
    return;
  }
  const n = Number(e.key);
  if (Number.isInteger(n) && n >= 1 && n <= 9) {
    const p = S.photos[n - 1];
    if (p) selectPhoto(p.id);
  }
});

startBtn.addEventListener('click', startCamera);
overlayStartBtn.addEventListener('click', startCamera);

/* ------------------------------------------------------------------ */
/* 启动                                                                */
/* ------------------------------------------------------------------ */
initSettings();
refreshState();
setInterval(refreshState, 1500);

window.addEventListener('beforeunload', () => {
  if (bc) bc.postMessage({ type: 'signal', state: 'bye' });
});
