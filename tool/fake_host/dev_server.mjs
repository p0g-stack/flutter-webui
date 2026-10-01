#!/usr/bin/env node
// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception
//
// Reference dev server for bootstrap/dev.html (docs/dev.md): serves a build
// directory, or fronts `flutter run -d web-server`, on 127.0.0.1 with the
// headers a page on the manager origin needs to load the app from it.
//
//   node tool/fake_host/dev_server.mjs --dir <build/web> [--port 8080]
//   node tool/fake_host/dev_server.mjs --proxy http://127.0.0.1:<flutter port> [--port 8080]
//
// No dependencies (node: modules only).

import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';

const USAGE = `usage: node tool/fake_host/dev_server.mjs (--dir <dir> | --proxy <url>) [options]
  --dir <dir>        serve this directory (a flutter build web output)
  --proxy <url>      forward to this server (flutter run -d web-server), adding the headers
  --port <n>         listen on 127.0.0.1:<n> (default 8080)
  --origin <origin>  allowed page origin (default https://mui.kernelsu.org)
  --fonts <dir>      serve /fonts/ from this directory (web_ui/tool/fallback_fonts.dart --out)
  --flutter <root>   Flutter SDK root, for the Roboto fallback in --proxy mode
                     (default: $FLUTTER_ROOT, else the flutter on PATH)
  --no-cors          send no CORS headers (to see what breaks)
  --no-pna           never answer Private Network Access preflights
  --quiet            do not log requests`;

const opts = { port: 8080, origin: 'https://mui.kernelsu.org', cors: true, pna: true, quiet: false };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const next = () => {
    if (i + 1 >= argv.length) fail(`${a} needs a value`);
    return argv[++i];
  };
  if (a === '--dir') opts.dir = path.resolve(next());
  else if (a === '--proxy') opts.proxy = new URL(next());
  else if (a === '--port') opts.port = Number(next());
  else if (a === '--origin') opts.origin = next();
  else if (a === '--fonts') opts.fonts = path.resolve(next());
  else if (a === '--flutter') opts.flutter = path.resolve(next());
  else if (a === '--no-cors') opts.cors = false;
  else if (a === '--no-pna') opts.pna = false;
  else if (a === '--quiet') opts.quiet = true;
  else if (a === '-h' || a === '--help') { console.log(USAGE); process.exit(0); }
  else fail(`unknown argument ${a}`);
}
if (!opts.dir === !opts.proxy) fail('give exactly one of --dir or --proxy');

// `flutter build web --no-web-resources-cdn` bundles Roboto as an asset, but
// `flutter run` does not, and the bootstrap keeps the engine off gstatic: in
// --proxy mode add it to FontManifest.json and serve it from the SDK.
const ROBOTO_ASSET = 'fonts/fallback/Roboto-Regular.ttf';
const robotoFile = (() => {
  if (!opts.proxy) return null;
  let root = opts.flutter ?? process.env.FLUTTER_ROOT;
  if (!root) {
    for (const dir of (process.env.PATH ?? '').split(path.delimiter)) {
      const bin = path.join(dir, 'flutter');
      if (fs.existsSync(bin)) { root = path.dirname(path.dirname(fs.realpathSync(bin))); break; }
    }
  }
  const file = root && path.join(root, 'engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf');
  if (file && fs.existsSync(file)) return file;
  console.warn('dev_server: no Roboto-Regular.ttf in the Flutter SDK (--flutter); text may not render');
  return null;
})();

function fail(message) {
  console.error(`dev_server: ${message}\n${USAGE}`);
  process.exit(2);
}

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json', '.css': 'text/css',
  '.map': 'application/json', '.png': 'image/png', '.ico': 'image/x-icon', '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff': 'font/woff', '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream', '.frag': 'application/octet-stream',
};

// The headers docs/dev.md requires, on every response including errors.
function corsHeaders(req) {
  if (!opts.cors) return {};
  const h = {
    'Access-Control-Allow-Origin': opts.origin,
    Vary: 'Origin',
    // Dev: never serve a stale module after a restart.
    'Cache-Control': 'no-store',
  };
  if (req.method === 'OPTIONS') {
    h['Access-Control-Allow-Methods'] = 'GET, HEAD, POST, OPTIONS';
    const asked = req.headers['access-control-request-headers'];
    if (asked) h['Access-Control-Allow-Headers'] = asked;
    h['Access-Control-Max-Age'] = '600';
    if (opts.pna && req.headers['access-control-request-private-network'] === 'true') {
      h['Access-Control-Allow-Private-Network'] = 'true';
    }
  }
  return h;
}

function log(req, status) {
  if (opts.quiet) return;
  const pna = req.headers['access-control-request-private-network'] ? ' [PNA preflight]' : '';
  console.log(`${status} ${req.method} ${req.url} origin=${req.headers.origin ?? '-'}${pna}`);
}

function serveFile(req, res, dir = opts.dir, prefix = '') {
  const url = new URL(req.url, 'http://x');
  let rel = decodeURIComponent(url.pathname).slice(prefix.length);
  if (rel.endsWith('/')) rel += 'index.html';
  const file = path.join(dir, path.normalize('/' + rel));
  if (!file.startsWith(dir + path.sep)) return send(req, res, 403, 'forbidden');
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) return send(req, res, 404, 'not found');
    res.writeHead(200, {
      ...corsHeaders(req),
      'Content-Type': TYPES[path.extname(file)] ?? 'application/octet-stream',
      'Content-Length': st.size,
    });
    log(req, 200);
    if (req.method === 'HEAD') return res.end();
    fs.createReadStream(file).pipe(res);
  });
}

function send(req, res, status, body) {
  res.writeHead(status, { ...corsHeaders(req), 'Content-Type': 'text/plain' });
  log(req, status);
  res.end(body);
}

// The Host header passes through unchanged: the debug service builds its
// WebSocket URL from it, so the page reaches it through this port too.
function proxy(req, res) {
  const pathname = new URL(req.url, 'http://x').pathname;
  if (robotoFile && pathname === `/assets/${ROBOTO_ASSET}`) {
    res.writeHead(200, { ...corsHeaders(req), 'Content-Type': 'font/ttf' });
    log(req, 200);
    return fs.createReadStream(robotoFile).pipe(res);
  }
  if (robotoFile && pathname === '/assets/FontManifest.json') {
    return proxyJson(req, res, (manifest) => {
      if (!manifest.some((e) => e.family === 'Roboto')) {
        manifest.push({ family: 'Roboto', fonts: [{ asset: ROBOTO_ASSET }] });
      }
      return manifest;
    });
  }
  if (pathname === '/reloaded_sources.json') {
    // Hot restart loads these with root-relative URLs, which the page would
    // resolve against the manager's origin: make them absolute.
    const self = `http://${req.headers.host}`;
    return proxyJson(req, res, (files) => files.map((f) => (
      typeof f.src === 'string' && f.src.startsWith('/') ? { ...f, src: self + f.src } : f
    )));
  }
  const up = http.request(
    { host: opts.proxy.hostname, port: opts.proxy.port, method: req.method, path: req.url, headers: req.headers },
    (upRes) => {
      const out = { ...upRes.headers };
      for (const k of Object.keys(out)) if (k.startsWith('access-control-')) delete out[k];
      res.writeHead(upRes.statusCode, { ...out, ...corsHeaders(req) });
      log(req, upRes.statusCode);
      upRes.pipe(res);
    },
  );
  up.on('error', (e) => send(req, res, 502, `upstream: ${e.message}`));
  req.pipe(up);
}

// Forwards a JSON file, changed by [edit].
function proxyJson(req, res, edit) {
  const headers = { ...req.headers };
  delete headers['accept-encoding'];
  delete headers['if-none-match'];
  delete headers['if-modified-since'];
  const up = http.get({ host: opts.proxy.hostname, port: opts.proxy.port, path: req.url, headers }, (upRes) => {
    const chunks = [];
    upRes.on('data', (c) => chunks.push(c));
    upRes.on('end', () => {
      let body = Buffer.concat(chunks).toString('utf8');
      try {
        body = JSON.stringify(edit(JSON.parse(body)));
      } catch {
        // Not the JSON we expected: pass it on as is.
      }
      res.writeHead(upRes.statusCode, { ...corsHeaders(req), 'Content-Type': 'application/json' });
      log(req, upRes.statusCode);
      res.end(body);
    });
  });
  up.on('error', (e) => send(req, res, 502, `upstream: ${e.message}`));
}

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(opts.cors ? 204 : 405, corsHeaders(req));
    log(req, opts.cors ? 204 : 405);
    return res.end();
  }
  if (opts.fonts && new URL(req.url, 'http://x').pathname.startsWith('/fonts/')) {
    return serveFile(req, res, opts.fonts, '/fonts');
  }
  if (opts.proxy) return proxy(req, res);
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(req, res, 405, 'method');
  serveFile(req, res);
});

// WebSocket upgrades (the debug service) pass through untouched.
server.on('upgrade', (req, socket, head) => {
  if (!opts.proxy) return socket.destroy();
  const up = net.connect(Number(opts.proxy.port), opts.proxy.hostname, () => {
    const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
    up.write(lines.join('\r\n') + '\r\n\r\n');
    up.write(head);
    socket.pipe(up).pipe(socket);
  });
  // A page that goes away must drop the debug service's client with it.
  up.on('error', () => socket.destroy());
  up.on('close', () => socket.destroy());
  socket.on('error', () => up.destroy());
  socket.on('close', () => up.destroy());
});

server.listen(opts.port, '127.0.0.1', () => {
  const what = opts.dir ? opts.dir : opts.proxy.href;
  console.log(`dev_server: http://127.0.0.1:${opts.port}/ -> ${what} (origin ${opts.cors ? opts.origin : 'none'})`);
});
