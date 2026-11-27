(() => {
  const doc = document;
  const root = doc.documentElement;
  const $ = (sel, el = doc) => el.querySelector(sel);
  const $$ = (sel, el = doc) => Array.from(el.querySelectorAll(sel));

  const T = {
    zh: {
      'nav.features': '功能', 'nav.screens': '界面', 'nav.architecture': '架构',
      'nav.performance': '性能', 'nav.install': '安装',
      'hero.title': '把换脸直播，<br><span class="grad">回到本机。</span>',
      'hero.lede': 'LiveFace Studio 用 SwiftUI + AVFoundation 直接采集，在本机完成换脸、换头、OBS 输出与录音录像。没有浏览器套壳，没有云端上传。',
      'hero.install': '开始安装', 'hero.github': '在 GitHub 查看',
      'hero.signal': '本地推理中', 'hero.float2': '固定延迟 · 不越拖越晚',
      'features.title': '不是网页套壳，<br>是为直播准备的原生工作台。',
      'features.lede': '从摄像头采集到 OBS 输出，每一层都为低延迟和可控性重新设计；所有画面只在本机流动。',
      'feature.native.title': '原生 SwiftUI + AVFoundation，<br>没有浏览器这层中间商。',
      'feature.native.body': '摄像头直采、本地服务复用、预览按摄像头时钟上屏。窗口、快捷键、设置和输出窗口都按 macOS 的方式工作。',
      'feature.head.title': '换脸，还是换头。',
      'feature.head.body': '换脸只替换面部；换头在换脸基础上叠加源照片的发型、耳朵和头部轮廓。强度、缩放、上下/左右均可微调。',
      'tag.experimental': '实验性',
      'feature.quality.title': '720p 到 4K，自己决定。',
      'feature.quality.body': '发送/输出画质、清晰度增强、GPEN-BFR-256 面部增强，外加流畅/均衡/清晰三档预设。',
      'feature.record.title': '录像，也可以暂停。',
      'feature.record.body': 'H.264 + AAC 同文件录制；倒计时、最长时长、码率、麦克风开关；暂停后继续不会留空洞。',
      'feature.obs.title': '为 OBS 留一个干净窗口。',
      'feature.obs.body': '无控件、黑底、16:9，可置顶、记忆位置；OBS 窗口采集即可，不把控制面板录进去。',
      'feature.privacy.title': '照片、画面、录音，默认不离开这台 Mac。',
      'feature.privacy.body': '服务只监听 127.0.0.1；没有账号、没有云同步。麦克风只在录制时启动；你可以随时关闭。README 里的截图全部来自空照片库。',
      'screens.title': '强大，但不用看说明书。',
      'screens.lede': '主界面只保留照片、模式、延迟和直播状态；设备、画质、录制、换头微调收进一个原生设置窗口。',
      'shots.main.title': '主界面', 'shots.main.desc': '原生 SwiftUI，清楚但不拥挤',
      'shots.main.sub': '照片库 · 模式 · 直播状态 · 顶部快捷截图/录制',
      'shots.quality.title': '画面与画质', 'shots.quality.desc': '分辨率、JPEG、清晰度、增强',
      'shots.quality.sub': '720p / 1080p / 4K · 发送/输出画质 · GPEN 面部增强',
      'shots.recording.title': '录制', 'shots.recording.desc': '同一个文件里暂停/继续',
      'shots.recording.sub': '倒计时 · 画质 · 最长录制 · 麦克风 · 最近文件',
      'shots.head.title': '换头', 'shots.head.desc': '头型、发型和轮廓的细调',
      'shots.head.sub': '模式 · 预设 · 强度 / 缩放 / 上下 / 左右',
      'arch.title': '一帧画面，<br>只走最短的路。',
      'arch.body': '摄像头直采，本地 HTTP 服务最多两帧并发；检测每 N 帧复用，积压时丢弃旧帧。换脸在 CoreML/ANE 上完成，结果回到预览、录制和 OBS 输出。',
      'arch.step1': '<b>采集。</b>AVFoundation 1280×720 / 1080p / 4K，JPEG + 8 字节时间戳。',
      'arch.step2': '<b>本机服务。</b>aiohttp 127.0.0.1:8787，2 个处理槽、检测缓存、目标锁定。',
      'arch.step3': '<b>推理。</b>inswapper_128 + CoreML；可选 GPEN-256 面部增强 / 头型融合。',
      'arch.step4': '<b>呈现。</b>固定延迟预览、PNG/MP4 录制、无控件 OBS 窗口。',
      'perf.title': '这台 M3 Pro 上，<br>数字是这样的。',
      'perf.lede': 'M3 Pro / 18GB，1280×720 基准，正确性优先。开启面部增强或 4K 会更慢，界面上都有明确提示。',
      'perf.k1': '720p 服务端呈现吞吐', 'perf.n1': '2 帧并发 · 检测复用 · 忙则丢拍',
      'perf.k2': '端到端 p50', 'perf.n2': '拍摄 → 服务端返回；p95 92.4ms',
      'perf.k3': '最高采集分辨率', 'perf.n3': '4/8/12/16/32 Mbps 录制可选；4K 对 M3 Pro 压力明显',
      'perf.k4': 'GPEN-256 测试帧率', 'perf.n4': '约 176–250ms/帧；清晰度换性能',
      'install.title': '一条命令，<br>把直播搬回本机。',
      'install.body': '需要 Apple Silicon Mac、macOS 14+、Python 3.12 和 Xcode Command Line Tools。安装脚本会创建虚拟环境、安装依赖并构建原生 App。',
      'install.hint': '首次启动会自动下载模型（约 1.2GB）并编译 CoreML，通常 1–3 分钟。之后 Spotlight 搜 LiveFace 即可。',
      'roadmap.title': '还会继续长出东西。',
      'roadmap.lede': '保持本地、原生、可控。下一个版本的重点是便携安装和更强的头部模型。',
      'road.1.t': '便携式 App', 'road.1.b': '内置 Python 运行时与模型，拷贝即用，不依赖本地环境。体积约 2–3GB。',
      'road.2.t': '更强的整头模型', 'road.2.b': '从 2D 头型/发型融合，走向更完整的 head reenactment 与生成式重建。',
      'road.3.t': '真实设备回归', 'road.3.b': '摄像头/麦克风、4K、UI 与长时间直播的自动化回归测试。',
      'footer.desc': '本地原生的实时换脸 / 换头工作台。基于 Deep-Live-Cam 的检测与换脸源码，App、服务与录制层为本项目增强。',
      'footer.legal': '仅用于本人或已获授权的人物形象。不要用于冒充、诈骗或误导。',
      'footer.handoff': '交接文档',
      'copy.copy': '复制', 'copy.done': '已复制', 'copy.selected': '已选中',
      'code.comment1': '# 公开仓库 · 整合版', 'code.comment2': '# 首次启动后：允许摄像头 / 麦克风',
      'code.comment3': '# 设置 → 画面 → 清晰优先（可选）',
      'lang.button': 'EN', 'theme.toLight': '切换到浅色模式', 'theme.toDark': '切换到深色模式'
    },
    en: {
      'nav.features': 'Features', 'nav.screens': 'Interface', 'nav.architecture': 'Architecture',
      'nav.performance': 'Performance', 'nav.install': 'Install',
      'hero.title': 'Face &amp; head swap.<br><span class="grad">Natively local.</span>',
      'hero.lede': 'LiveFace Studio captures with SwiftUI + AVFoundation and swaps faces or heads entirely on-device. No browser wrapper. No cloud upload.',
      'hero.install': 'Install now', 'hero.github': 'View on GitHub',
      'hero.signal': 'Inference on-device', 'hero.float2': 'Fixed delay · never falls behind',
      'features.title': 'Not a web wrapper.<br>A native desk for live video.',
      'features.lede': 'From capture to OBS output, every layer is rebuilt for low latency and control. Every pixel stays on this Mac.',
      'feature.native.title': 'SwiftUI + AVFoundation.<br>No browser in the middle.',
      'feature.native.body': 'Direct camera capture, a reused local service, and preview timing on the camera clock. Windows, shortcuts, settings and output all work the macOS way.',
      'feature.head.title': 'Swap a face. Or a whole head.',
      'feature.head.body': 'Face mode replaces the face only. Head mode adds the source hair, ears and head outline, with strength, scale and X/Y controls.',
      'tag.experimental': 'Experimental',
      'feature.quality.title': '720p to 4K. Your call.',
      'feature.quality.body': 'Send/output JPEG quality, sharpening, optional GPEN-BFR-256 face restoration, plus Smooth / Balanced / Clear presets.',
      'feature.record.title': 'Record. Pause. Continue.',
      'feature.record.body': 'H.264 + AAC in one file, countdown, max duration, bitrate and a mic switch. Pause removes the gap when you resume.',
      'feature.obs.title': 'A clean window for OBS.',
      'feature.obs.body': 'No controls, black canvas, 16:9. Float it, remember its frame, and capture it as a window source without the control panel.',
      'feature.privacy.title': 'Photos, frames and audio stay on this Mac.',
      'feature.privacy.body': 'The service only listens on 127.0.0.1. No accounts, no cloud sync. The mic runs only while recording and can be switched off. README screenshots use an empty library.',
      'screens.title': 'Powerful. Without a manual.',
      'screens.lede': 'The sidebar keeps photos, mode, delay and live status. Devices, quality, recording and head tuning live in one native Settings window.',
      'shots.main.title': 'Main window', 'shots.main.desc': 'Native SwiftUI, clear but not crowded',
      'shots.main.sub': 'Library · Mode · Live status · Quick capture/record',
      'shots.quality.title': 'Video & quality', 'shots.quality.desc': 'Resolution, JPEG, sharpness, enhancement',
      'shots.quality.sub': '720p / 1080p / 4K · Send/output quality · GPEN face enhancement',
      'shots.recording.title': 'Recording', 'shots.recording.desc': 'Pause and resume in one file',
      'shots.recording.sub': 'Countdown · Bitrate · Max duration · Mic · Recent files',
      'shots.head.title': 'Head mode', 'shots.head.desc': 'Fine-tune head shape and hair',
      'shots.head.sub': 'Mode · Presets · Strength / Scale / X / Y',
      'arch.title': 'One frame.<br>The shortest possible path.',
      'arch.body': 'Direct camera capture feeds a local HTTP service with at most two frames in flight. Detection is reused every N frames; stale queued frames are dropped. Swap runs on CoreML/ANE and returns to preview, recording and OBS.',
      'arch.step1': '<b>Capture.</b>AVFoundation at 1280×720 / 1080p / 4K, JPEG + an 8-byte timestamp.',
      'arch.step2': '<b>Local service.</b>aiohttp on 127.0.0.1:8787, two workers, detection cache, target lock.',
      'arch.step3': '<b>Inference.</b>inswapper_128 + CoreML; optional GPEN-256 face restoration / head transfer.',
      'arch.step4': '<b>Present.</b>Fixed-delay preview, PNG/MP4 recording, a control-free OBS window.',
      'perf.title': 'On this M3 Pro,<br>the numbers look like this.',
      'perf.lede': 'M3 Pro / 18GB, 1280×720 baseline. Face enhancement and 4K are slower; the UI says so before you switch.',
      'perf.k1': '720p server presentation', 'perf.n1': '2 frames in flight · detection reuse · drop when busy',
      'perf.k2': 'End-to-end p50', 'perf.n2': 'Capture → server response; p95 92.4ms',
      'perf.k3': 'Max capture resolution', 'perf.n3': '4/8/12/16/32 Mbps recording; 4K is heavy on M3 Pro',
      'perf.k4': 'GPEN-256 test frame rate', 'perf.n4': 'About 176–250ms/frame; clarity costs speed',
      'install.title': 'One command.<br>Bring the studio home.',
      'install.body': 'Requires an Apple Silicon Mac, macOS 14+, Python 3.12 and Xcode Command Line Tools. The script creates a virtualenv, installs dependencies and builds the native app.',
      'install.hint': 'First launch downloads models (about 1.2GB) and compiles CoreML, usually 1–3 minutes. After that, find LiveFace in Spotlight.',
      'roadmap.title': 'Still growing.',
      'roadmap.lede': 'Local, native and controllable. Next: portable packaging and a stronger head model.',
      'road.1.t': 'Portable app', 'road.1.b': 'Embed the Python runtime and models. Copy, open, run—no local setup. About 2–3GB.',
      'road.2.t': 'Stronger head model', 'road.2.b': 'From 2D head/hair transfer toward full head reenactment and generative reconstruction.',
      'road.3.t': 'Real-device regression', 'road.3.b': 'Camera/mic, 4K, UI and long-session automated regression tests.',
      'footer.desc': 'A local-first real-time face and head studio. Detection and swap source from Deep-Live-Cam; the native app, service and recording layers are project enhancements.',
      'footer.legal': 'Use only with your own likeness or authorized subjects. Never for impersonation, fraud or misleading content.',
      'footer.handoff': 'Handoff',
      'copy.copy': 'Copy', 'copy.done': 'Copied', 'copy.selected': 'Selected',
      'code.comment1': '# Public integrated repo', 'code.comment2': '# After first launch: allow camera / microphone',
      'code.comment3': '# Settings → Video → Clear preset (optional)',
      'lang.button': '中', 'theme.toLight': 'Switch to light mode', 'theme.toDark': 'Switch to dark mode'
    }
  };

  const getLang = () => {
    try {
      const saved = localStorage.getItem('lf-lang');
      if (saved === 'zh' || saved === 'en') return saved;
    } catch {}
    return (navigator.language || '').toLowerCase().startsWith('zh') ? 'zh' : 'en';
  };
  let lang = getLang();
  if (lang !== 'zh' && lang !== 'en') lang = 'zh';

  const themeBtn = $('#themeBtn');
  const langBtn = $('#langBtn');
  const theme = () => root.dataset.theme || 'dark';
  const applyTheme = (value) => {
    root.dataset.theme = value;
    try { localStorage.setItem('lf-theme', value); } catch {}
    const meta = $('meta[name="theme-color"]');
    if (meta) meta.content = value === 'light' ? '#f4f7fc' : '#05070b';
    if (themeBtn) {
      themeBtn.setAttribute('aria-label', T[lang][value === 'light' ? 'theme.toDark' : 'theme.toLight']);
      themeBtn.title = T[lang][value === 'light' ? 'theme.toDark' : 'theme.toLight'];
    }
  };

  const shotKeys = ['main', 'quality', 'recording', 'head'];
  const stageImg = $('#stageImg');
  const stageTitle = $('#stageTitle');
  const stageSub = $('#stageSub');
  const thumbs = $$('.thumb');
  let activeShot = 'main';

  const selectShot = (btn, updateActive = true) => {
    if (!btn) return;
    const key = btn.dataset.shot;
    if (!key || !shotKeys.includes(key)) return;
    activeShot = key;
    const title = T[lang][`shots.${key}.title`];
    const sub = T[lang][`shots.${key}.sub`];
    if (stageTitle) stageTitle.textContent = title;
    if (stageSub) stageSub.textContent = sub;
    if (stageImg && btn.dataset.img) {
      const src = btn.dataset.img;
      stageImg.style.opacity = '0';
      const next = new Image();
      next.onload = () => {
        stageImg.src = src;
        stageImg.alt = title || 'LiveFace';
        stageImg.style.opacity = '1';
      };
      next.src = src;
    }
    if (updateActive) {
      thumbs.forEach((t) => {
        const active = t === btn;
        t.classList.toggle('active', active);
        t.setAttribute('aria-selected', String(active));
      });
    }
  };

  const applyLanguage = (value) => {
    lang = value === 'en' ? 'en' : 'zh';
    root.lang = lang === 'zh' ? 'zh-CN' : 'en';
    try { localStorage.setItem('lf-lang', lang); } catch {}
    $$('[data-i18n]').forEach((el) => {
      const key = el.dataset.i18n;
      if (T[lang][key] != null) el.textContent = T[lang][key];
    });
    $$('[data-i18n-html]').forEach((el) => {
      const key = el.dataset.i18nHtml;
      if (T[lang][key] != null) el.innerHTML = T[lang][key];
    });
    if (langBtn) {
      langBtn.textContent = T[lang]['lang.button'];
      langBtn.setAttribute('aria-label', lang === 'zh' ? 'Switch to English' : '切换到中文');
      langBtn.title = lang === 'zh' ? 'Switch to English' : '切换到中文';
    }
    const copyBtn = $('#copyBtn');
    if (copyBtn) copyBtn.textContent = T[lang]['copy.copy'];
    if (themeBtn) themeBtn.setAttribute('aria-label', T[lang][theme() === 'light' ? 'theme.toDark' : 'theme.toLight']);
    const title = lang === 'zh'
      ? 'LiveFace Studio — 本地原生实时换脸与换头'
      : 'LiveFace Studio — Native real-time face & head swap for macOS';
    doc.title = title;
    const desc = $('meta[name="description"]');
    if (desc) desc.content = lang === 'zh'
      ? 'LiveFace Studio 是 Apple Silicon Mac 上的原生实时换脸/换头 App：SwiftUI、AVFoundation、CoreML，本地完成，OBS 输出、4K 与 GPEN 面部增强。'
      : 'LiveFace Studio is a native real-time face and head swap app for Apple Silicon Macs: SwiftUI, AVFoundation, CoreML, local-only, OBS-ready, 4K and GPEN face enhancement.';
    const active = thumbs.find((t) => t.classList.contains('active')) || thumbs[0];
    if (active) selectShot(active, false);
  };

  langBtn?.addEventListener('click', () => applyLanguage(lang === 'zh' ? 'en' : 'zh'));
  themeBtn?.addEventListener('click', () => applyTheme(theme() === 'light' ? 'dark' : 'light'));

  // mobile menu
  const menu = $('#mobileMenu');
  const menuBtn = $('#menuBtn');
  const menuClose = $('#menuClose');
  const setMenu = (open) => {
    if (!menu || !menuBtn) return;
    menu.classList.toggle('open', open);
    menuBtn.classList.toggle('open', open);
    menuBtn.setAttribute('aria-expanded', String(open));
    menu.setAttribute('aria-hidden', String(!open));
    doc.body.style.overflow = open ? 'hidden' : '';
  };
  menuBtn?.addEventListener('click', () => setMenu(!menu?.classList.contains('open')));
  menuClose?.addEventListener('click', () => setMenu(false));
  menu?.querySelectorAll('a').forEach((a) => a.addEventListener('click', () => setMenu(false)));
  window.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') setMenu(false);
  });

  thumbs.forEach((btn, index) => {
    btn.addEventListener('click', () => selectShot(btn));
    btn.addEventListener('keydown', (e) => {
      if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
      e.preventDefault();
      const next = (index + (e.key === 'ArrowRight' ? 1 : thumbs.length - 1)) % thumbs.length;
      thumbs[next].focus();
      selectShot(thumbs[next]);
    });
  });

  // lightbox
  const lightbox = $('#lightbox');
  const lightboxImg = $('#lightboxImg');
  const lightboxClose = $('#lightboxClose');
  stageImg?.addEventListener('click', () => {
    if (!lightbox || !lightboxImg) return;
    lightboxImg.src = stageImg.src;
    lightboxImg.alt = stageImg.alt;
    if (typeof lightbox.showModal === 'function') lightbox.showModal();
  });
  lightboxClose?.addEventListener('click', () => lightbox?.close());
  lightbox?.addEventListener('click', (e) => { if (e.target === lightbox) lightbox.close(); });

  // copy
  const copyBtn = $('#copyBtn');
  const installCode = $('#installCode');
  copyBtn?.addEventListener('click', async () => {
    if (!installCode) return;
    const text = installCode.innerText;
    try {
      await navigator.clipboard.writeText(text);
      copyBtn.textContent = T[lang]['copy.done'];
    } catch {
      const range = doc.createRange();
      range.selectNodeContents(installCode);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
      copyBtn.textContent = T[lang]['copy.selected'];
    }
    setTimeout(() => { copyBtn.textContent = T[lang]['copy.copy']; }, 1800);
  });

  // reveal on entry
  const reveals = $$('.reveal');
  if ('IntersectionObserver' in window && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const io = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add('in');
          io.unobserve(entry.target);
        }
      }
    }, { rootMargin: '0px 0px -10% 0px', threshold: 0.08 });
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add('in'));
  }

  const year = $('#year');
  if (year) year.textContent = String(new Date().getFullYear());

  applyTheme(theme());
  applyLanguage(lang);
})();
