#!/usr/bin/env node
// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception
//
// A fake root manager in headless Chromium: serves a module webroot at
// https://mui.kernelsu.org/ (route interception, nothing listens), injects the
// bridge of one host profile (the profiles of FakeBridge in
// packages/flutter_webui_client/lib/testing.dart and docs/hosts.md), logs what
// the page asks of the host, and fails if Flutter shows no first frame.
// Usage: see USAGE below, or docs/dev.md.

import { execFile, execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const USAGE = `usage: node tool/fake_host/fake_host.mjs --webroot <dir> [options]
  --webroot <dir>       module webroot (a flutter build web output with the bootstrap)
  --host <profile>      kernelsu | next | apatch | webuix | browser (default kernelsu)
  --entry <path>        page to open (default index.html; e.g. 'dev.html?dev=http://127.0.0.1:8080/')
  --dark                dark system theme (prefers-color-scheme, and $<id>.isDarkMode() on webuix)
  --insets T,B|T,R,B,L  safe-area insets in px (default: the profile's; 0 turns them off)
  --module-id <id>      module id (default: the page's webui-module-id meta, else "demo")
  --events <list>       after the first frame, in order: pause, resume, back, tap[@x:y], wait<ms>
                        (e.g. tap,wait500,back,pause,wait2000,resume,back; tap is the viewport centre)
  --exec-local          run ksu.exec commands with /bin/sh on this machine (default: run nothing, exit 0)
  --screenshot <png>    screenshot after the first frame and events
  --timeout <s>         seconds to wait for the first frame (default 60)
  --hold <s>            keep the page open this long at the end (default 1)
  --viewport WxH        CSS px (default 412x860)
  --deny-local-network  do not grant Local Network Access (dev.html then cannot reach 127.0.0.1)
  --csp <policy>        send this Content-Security-Policy with HTML pages (as WebUI X adds one)
  --late-globals <ms>   define ksu, webui and $<id> this long after page start (as WebUI X does)
  --verbose             also log headless Chromium's software-GL console noise
exit status: 0 first frame seen, 1 no first frame (or the page died), 2 bad usage`;

const PROFILES = {
  // KernelSU, SukiSU: full bridge, edge-to-edge via enableEdgeToEdge, insets.css.
  kernelsu: {
    ksu: ['exec', 'spawn', 'toast', 'fullScreen', 'enableEdgeToEdge', 'moduleInfo', 'listPackages', 'getPackagesInfo', 'exit'],
    insetsCss: true, insets: [24, 0, 48, 0], missing: 'empty200', cachedCanGoBack: true,
  },
  // KernelSU Next: enableInsets, no exit.
  next: {
    ksu: ['exec', 'spawn', 'toast', 'fullScreen', 'enableInsets', 'moduleInfo', 'listPackages', 'getPackagesInfo'],
    insetsCss: true, insets: [24, 0, 48, 0], missing: 'empty200',
  },
  // APatch: no moduleInfo (the module id comes from the meta tag), no exit.
  apatch: {
    ksu: ['exec', 'spawn', 'toast', 'fullScreen', 'enableInsets', 'listPackages', 'getPackagesInfo'],
    insetsCss: false, insets: null, missing: 'empty200',
  },
  // WebUI X Portable / MMRL: ksu.mmrl, window.webui, $<id>.isDarkMode(), WX_* events.
  webuix: {
    ksu: ['exec', 'spawn', 'toast', 'fullScreen', 'moduleInfo', 'mmrl'],
    webui: ['exit', 'startActivity'],
    insetsCss: true, insets: [30, 0, 20, 0], missing: '404', wx: true,
  },
  // A browser tab: no globals at all.
  browser: { ksu: [], insetsCss: false, insets: null, missing: '404', bare: true },
};

const ORIGIN = 'https://mui.kernelsu.org';

const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm',
  '.json': 'application/json', '.css': 'text/css', '.map': 'application/json', '.png': 'image/png',
  '.ico': 'image/x-icon', '.svg': 'image/svg+xml', '.ttf': 'font/ttf', '.otf': 'font/otf',
  '.woff': 'font/woff', '.woff2': 'font/woff2',
};

function usage(message) {
  if (message) console.error(`fake_host: ${message}`);
  console.error(USAGE);
  process.exit(2);
}

function parseArgs(argv) {
  const o = { host: 'kernelsu', entry: 'index.html', dark: false, events: [], execLocal: false, timeout: 60, hold: 1, viewport: [412, 860] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => (i + 1 < argv.length ? argv[++i] : usage(`${a} needs a value`));
    switch (a) {
      case '--webroot': o.webroot = path.resolve(next()); break;
      case '--host': o.host = next(); break;
      case '--entry': o.entry = next().replace(/^\//, ''); break;
      case '--dark': o.dark = true; break;
      case '--insets': {
        const n = next().split(',').map(Number);
        if (n.some(Number.isNaN) || ![1, 2, 4].includes(n.length)) usage('--insets takes T,B or T,R,B,L');
        o.insets = n.length === 4 ? n : n.length === 2 ? [n[0], 0, n[1], 0] : [n[0], n[0], n[0], n[0]];
        break;
      }
      case '--module-id': o.moduleId = next(); break;
      case '--events': o.events = next().split(',').map((s) => s.trim()).filter(Boolean); break;
      case '--exec-local': o.execLocal = true; break;
      case '--screenshot': o.screenshot = path.resolve(next()); break;
      case '--timeout': o.timeout = Number(next()); break;
      case '--hold': o.hold = Number(next()); break;
      case '--viewport': o.viewport = next().split('x').map(Number); break;
      case '--late-globals': o.late = Number(next()); break;
      case '--verbose': o.verbose = true; break;
      case '--csp': o.csp = next(); break;
      case '--deny-local-network': o.denyLocalNetwork = true; break;
      case '-h': case '--help': console.log(USAGE); process.exit(0);
      default: usage(`unknown argument ${a}`);
    }
  }
  if (!o.webroot) usage('--webroot is required');
  if (!fs.existsSync(o.webroot)) usage(`no such directory: ${o.webroot}`);
  if (!PROFILES[o.host]) usage(`unknown host ${o.host}`);
  for (const e of o.events) if (!/^(pause|resume|back|wait\d+|tap(@\d+:\d+)?)$/.test(e)) usage(`unknown event ${e}`);
  return o;
}

// Playwright from tool/fake_host/node_modules (npm ci), else the global install.
async function loadPlaywright() {
  try {
    return await import('playwright');
  } catch {
    const root = execSync('npm root -g', { encoding: 'utf8' }).trim();
    const entry = path.join(root, 'playwright', 'index.mjs');
    if (!fs.existsSync(entry)) {
      console.error('fake_host: playwright not found. Run `npm ci` in tool/fake_host, or install it globally.');
      process.exit(2);
    }
    return import(pathToFileURL(entry).href);
  }
}

const out = (tag, text) => console.log(`[${tag}] ${text}`);

function moduleIdFromMeta(webroot, entry) {
  const file = path.join(webroot, entry.split('?')[0]);
  try {
    const html = fs.readFileSync(file, 'utf8');
    const m = html.match(/<meta\s+name="webui-module-id"\s+content="([^"]*)"/);
    return m && m[1] ? m[1] : null;
  } catch {
    return null;
  }
}

// Runs in the page before any of its scripts.
function installBridge(cfg) {
  const call = (name, args) => window.__fakeHostCall(name, JSON.stringify(args));
  if (cfg.bare) return;
  const ksu = {};
  const methods = {
    exec(cmd, options, callbackName) {
      call('ksu.exec', [cmd]);
      window.__fakeHostExec(cmd).then(([code, stdout, stderr]) => {
        const cb = window[callbackName];
        if (typeof cb === 'function') cb(code, stdout, stderr);
      });
    },
    spawn(cmd, args) { call('ksu.spawn', [cmd, args]); },
    toast(text) { call('ksu.toast', [text]); },
    fullScreen(on) { call('ksu.fullScreen', [on]); },
    enableEdgeToEdge(on) { call('ksu.enableEdgeToEdge', [on]); },
    enableInsets(on) { call('ksu.enableInsets', [on]); },
    moduleInfo() { call('ksu.moduleInfo', []); return JSON.stringify(cfg.info); },
    listPackages(type) { call('ksu.listPackages', [type]); return '[]'; },
    getPackagesInfo(pkgs) { call('ksu.getPackagesInfo', [pkgs]); return '[]'; },
    exit() { call('ksu.exit', []); },
    mmrl() { return true; },
  };
  for (const name of cfg.ksu) ksu[name] = methods[name];
  // WebUI X defines its globals after the page starts (devicelab: undefined at
  // document start); --late-globals <ms> does the same.
  const define = (fn) => (cfg.late == null ? fn() : setTimeout(fn, cfg.late));
  define(() => { window.ksu = ksu; });
  if (cfg.webui) {
    const webui = {
      exit() { call('webui.exit', []); },
      startActivity(intent) { call('webui.startActivity', [intent]); },
    };
    const global = '$' + cfg.info.id.replace(/[^a-zA-Z0-9_]/g, '_');
    define(() => {
      window.webui = Object.fromEntries(cfg.webui.map((n) => [n, webui[n]]));
      window[global] = { isDarkMode() { call(global + '.isDarkMode', []); return cfg.dark; } };
    });
  }
  if (cfg.wx && cfg.insets) {
    // WebUI X injects the variables itself rather than through a stylesheet.
    const [t, r, b, l] = cfg.insets;
    const set = () => {
      const s = document.documentElement.style;
      s.setProperty('--safe-area-inset-top', t + 'px');
      s.setProperty('--safe-area-inset-right', r + 'px');
      s.setProperty('--safe-area-inset-bottom', b + 'px');
      s.setProperty('--safe-area-inset-left', l + 'px');
    };
    document.documentElement ? set() : document.addEventListener('DOMContentLoaded', set);
  }
}

function pageWatch() {
  document.addEventListener('securitypolicyviolation', (e) => {
    window.__fakeHostCsp(`blocked ${e.blockedURI || '(inline)'} by ${e.effectiveDirective}`);
  });
  window.addEventListener('flutter-first-frame', () => window.__fakeHostFirstFrame(Math.round(performance.now())));
  document.addEventListener('visibilitychange', () => window.__fakeHostCall('page.visibilitychange', JSON.stringify([document.visibilityState])));
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const profile = PROFILES[o.host];
  const moduleId = o.moduleId ?? moduleIdFromMeta(o.webroot, o.entry) ?? 'demo';
  const insets = o.insets ?? profile.insets;
  const hasInsets = insets && insets.some((v) => v !== 0);
  const cfg = {
    ksu: profile.ksu, webui: profile.webui, wx: !!profile.wx, bare: !!profile.bare, dark: o.dark,
    info: { id: moduleId, name: moduleId, moduleDir: `/data/adb/modules/${moduleId}` },
    insets: hasInsets ? insets : null,
    late: o.late ?? null,
  };

  out('fake_host', `host=${o.host} module=${moduleId} webroot=${o.webroot} entry=${ORIGIN}/${o.entry}`);
  const { chromium } = await loadPlaywright();
  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: { width: o.viewport[0], height: o.viewport[1] },
    colorScheme: o.dark ? 'dark' : 'light',
    locale: 'en-US',
    serviceWorkers: 'block',
  });
  if (!o.denyLocalNetwork) {
    // Chromium 141+ asks before a public page reaches 127.0.0.1 (Local Network
    // Access); headless denies. Grant it as a user would, for dev.html.
    await context.grantPermissions(['local-network-access'], { origin: ORIGIN })
      .catch((e) => out('fake_host', `cannot grant local-network-access: ${e.message.split('\n')[0]}`));
  }
  const page = await context.newPage();

  let firstFrame = null;
  let died = null;
  page.on('console', (m) => {
    // Headless Chromium's software-GL chatter, not the page's.
    if (!o.verbose && /GroupMarkerNotSet|GL Driver Message|swiftshader/.test(m.text())) return;
    out(`console.${m.type()}`, m.text());
  });
  page.on('pageerror', (e) => out('pageerror', e.message));
  await page.exposeFunction('__fakeHostCsp', (v) => out('csp', v));
  page.on('crash', () => { died = 'page crashed'; });
  page.on('requestfailed', (r) => out('requestfailed', `${r.url()} ${r.failure()?.errorText ?? ''}`));
  let lastUrl = null;
  page.on('framenavigated', (f) => {
    // Also fires for history.pushState/replaceState; log URL changes only.
    if (f !== page.mainFrame() || f.url() === lastUrl) return;
    lastUrl = f.url();
    out('navigate', lastUrl);
  });
  page.on('close', () => { died ??= 'page closed'; });

  await page.exposeFunction('__fakeHostCall', (name, json) => {
    const args = JSON.parse(json).map((a) => JSON.stringify(a) ?? 'undefined').join(', ');
    out(name.startsWith('page.') ? 'lifecycle' : 'bridge', `${name}(${args})`);
  });
  await page.exposeFunction('__fakeHostFirstFrame', (ms) => {
    if (firstFrame === null) out('flutter', `first frame at ${ms} ms`);
    firstFrame ??= ms;
  });
  await page.exposeFunction('__fakeHostExec', (cmd) => {
    if (!o.execLocal) return [0, '', ''];
    return new Promise((resolve) => execFile('/bin/sh', ['-c', cmd], { timeout: 30000 }, (err, stdout, stderr) => {
      const code = err ? (typeof err.code === 'number' ? err.code : 1) : 0;
      out('exec', `exit ${code}: ${cmd}`);
      resolve([code, stdout, stderr]);
    }));
  });
  await page.addInitScript(installBridge, cfg);
  await page.addInitScript(pageWatch);
  if (!profile.wx && !profile.bare) await page.addInitScript(historyModel, !!profile.cachedCanGoBack);

  await page.route(`${ORIGIN}/**`, async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === '/internal/insets.css') {
      if (!profile.insetsCss) return fulfillMissing(route, profile);
      const [t, r, b, l] = cfg.insets ?? [0, 0, 0, 0];
      return route.fulfill({
        contentType: 'text/css',
        body: `:root{--safe-area-inset-top:${t}px;--safe-area-inset-right:${r}px;--safe-area-inset-bottom:${b}px;--safe-area-inset-left:${l}px}`,
      });
    }
    let rel = decodeURIComponent(url.pathname);
    if (rel.endsWith('/')) rel += 'index.html';
    const file = path.join(o.webroot, path.normalize(rel));
    if (!file.startsWith(o.webroot) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      out('missing', `${url.pathname} (answered ${profile.missing === 'empty200' ? 'empty 200, as KernelSU does' : '404'})`);
      return fulfillMissing(route, profile);
    }
    const ext = path.extname(file);
    const headers = o.csp && ext === '.html' ? { 'Content-Security-Policy': o.csp } : {};
    return route.fulfill({ contentType: TYPES[ext] ?? 'application/octet-stream', headers, body: fs.readFileSync(file) });
  });

  await page.goto(`${ORIGIN}/${o.entry}`).catch((e) => out('navigate', `failed: ${e.message}`));
  const deadline = Date.now() + o.timeout * 1000;
  while (firstFrame === null && !died && Date.now() < deadline) await sleep(100);
  if (firstFrame === null) {
    out('result', `FAIL: no first frame within ${o.timeout} s${died ? ` (${died})` : ''}`);
    if (o.screenshot && !died) await page.screenshot({ path: o.screenshot }).catch(() => {});
    await browser.close();
    process.exit(1);
  }
  await sleep(300);

  for (const event of o.events) {
    if (died) break;
    await sendEvent(page, event, profile);
    await sleep(300);
  }
  if (o.screenshot && !died) {
    await page.screenshot({ path: o.screenshot });
    out('fake_host', `screenshot ${o.screenshot}`);
  }
  if (o.hold > 0 && !died) await sleep(o.hold * 1000);
  out('result', `OK: first frame at ${firstFrame} ms${died ? `; then ${died}` : ''}`);
  await browser.close();
}

function fulfillMissing(route, profile) {
  // KernelSU-family loaders answer a missing file with an empty 200.
  return profile.missing === 'empty200'
    ? route.fulfill({ status: 200, body: '' })
    : route.fulfill({ status: 404, contentType: 'text/plain', body: 'not found' });
}

// WebView.canGoBack() as Chromium answers it: its history intervention skips
// an entry the page left by pushState without user activation, and user
// activation unmarks the document's skipped entries. KernelSU reads
// canGoBack() only on doUpdateVisitedHistory (pushState, replaceState,
// traversals); Next reads it at Back. Tracks this document's session history.
function historyModel(cached) {
  const h = window.history;
  const model = { entries: [{ skip: false }], index: 0 };
  window.__fakeHostHistory = model;
  // Transient activation from trusted input only, as Chromium grants it for
  // 5 s (navigator.userActivation also counts Playwright's evaluate calls).
  let activatedAt = -Infinity;
  const activeNow = () => performance.now() - activatedAt < 5000;
  for (const type of ['keydown', 'mousedown', 'pointerup', 'touchend']) {
    window.addEventListener(type, (e) => {
      if (!e.isTrusted) return;
      activatedAt = performance.now();
      for (const entry of model.entries) entry.skip = false;
    }, true);
  }
  const push = h.pushState.bind(h);
  const replace = h.replaceState.bind(h);
  const go = h.go.bind(h);
  const offset = () => {
    for (let i = model.index - 1; i >= 0; i--) if (!model.entries[i].skip) return i - model.index;
    return 0;
  };
  let seen = 0; // canGoBack() as of the last doUpdateVisitedHistory
  const visited = () => { seen = offset(); };
  h.pushState = (...args) => {
    if (!activeNow()) model.entries[model.index].skip = true;
    model.entries.length = model.index + 1;
    model.entries.push({ skip: false });
    model.index++;
    const r = push(...args);
    visited();
    return r;
  };
  h.replaceState = (...args) => {
    const r = replace(...args);
    visited();
    return r;
  };
  h.go = (n = 0) => {
    model.index = Math.max(0, Math.min(model.entries.length - 1, model.index + n));
    return go(n);
  };
  window.addEventListener('popstate', visited, true);
  visited();
  h.back = () => h.go(-1);
  h.forward = () => h.go(1);
  // Offset of the entry WebView.goBack() goes to, or 0 when the host's
  // canGoBack() is false (KernelSU: as last seen).
  model.backOffset = () => (cached && !seen ? 0 : offset());
}

async function sendEvent(page, event, profile) {
  const wait = event.match(/^wait(\d+)$/);
  if (wait) {
    out('lifecycle', `wait ${wait[1]} ms`);
    return sleep(Number(wait[1]));
  }
  const tap = event.match(/^tap(?:@(\d+):(\d+))?$/);
  if (tap) {
    const vp = page.viewportSize();
    const [x, y] = tap[1] ? [Number(tap[1]), Number(tap[2])] : [vp.width / 2, vp.height / 2];
    out('lifecycle', `tap at ${x},${y}`);
    return page.mouse.click(x, y);
  }
  if (profile.wx) {
    const type = { pause: 'WX_ON_PAUSE', resume: 'WX_ON_RESUME', back: 'WX_ON_BACK' }[event];
    out('lifecycle', `${event}: postMessage ${type}`);
    return page.evaluate((t) => window.postMessage(JSON.stringify({ type: t }), '*'), type);
  }
  if (event === 'back') {
    // The KernelSU-family activity: WebView.goBack() if canGoBack(), else finish().
    if (profile.bare) {
      out('lifecycle', 'back: history.back()');
      return page.evaluate(() => history.back());
    }
    const offset = await page.evaluate(() => window.__fakeHostHistory.backOffset());
    out('lifecycle', `back: ${offset ? `canGoBack, history.go(${offset})` : 'canGoBack() false, the activity would finish'}`);
    if (offset) await page.evaluate((n) => history.go(n), offset);
    return;
  }
  // Pause/resume as a hidden/visible tab, as WebView.onPause() does
  // (docs/hosts.md).
  const state = event === 'pause' ? 'hidden' : 'visible';
  out('lifecycle', `${event}: visibilityState=${state}`);
  return page.evaluate((s) => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => s });
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => s === 'hidden' });
    document.dispatchEvent(new Event('visibilitychange'));
  }, state);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

main().catch((e) => {
  out('result', `FAIL: ${e.stack ?? e}`);
  process.exit(1);
});
