// Phase 3.2: side-by-side fingerprint diff of patched vs stock Firefox.
// Launches each binary against the same loopback HTTP test page, captures
// every surface the weles patches touch, prints a diff table.

import { existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { globSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const BUILD_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const patched = join(BUILD_ROOT, 'mozilla-central/obj-weles/dist/Nightly.app/Contents/MacOS/firefox');
if (!existsSync(patched)) { console.error(`FAIL: patched binary missing at ${patched}`); process.exit(1); }

const stockMatches = globSync(`${process.env.HOME}/Library/Caches/ms-playwright/firefox-*/firefox/Nightly.app/Contents/MacOS/firefox`);
const stock = stockMatches[stockMatches.length - 1];
if (!stock) { console.error('FAIL: no Playwright-bundled Firefox found'); process.exit(1); }

const welesPrefs = {
  webgl: { vendor: 'Apple Inc. (weles test)', renderer: 'Apple M9 Ultra (weles test)' },
  screen: { width: 2048, height: 1536, aw: 2048, ah: 1500 },
  window: { ow: 2050, oh: 1616, x: 42, y: 24 },
};

async function capture(binary) {
  const profile = mkdtempSync(join(tmpdir(), 'weles-diff-'));
  const prefLines = [
    'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("browser.startup.page", 0);',
    'user_pref("browser.startup.homepage_override.mstone", "ignore");',
    'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
    'user_pref("datareporting.policy.firstRunURL", "");',
    'user_pref("weles.fingerprint.webdriver.force", true);',
    `user_pref("weles.fingerprint.webgl.vendor", "${welesPrefs.webgl.vendor}");`,
    `user_pref("weles.fingerprint.webgl.renderer", "${welesPrefs.webgl.renderer}");`,
    `user_pref("weles.fingerprint.screen.width", ${welesPrefs.screen.width});`,
    `user_pref("weles.fingerprint.screen.height", ${welesPrefs.screen.height});`,
    `user_pref("weles.fingerprint.screen.avail_width", ${welesPrefs.screen.aw});`,
    `user_pref("weles.fingerprint.screen.avail_height", ${welesPrefs.screen.ah});`,
    `user_pref("weles.fingerprint.window.outer_width", ${welesPrefs.window.ow});`,
    `user_pref("weles.fingerprint.window.outer_height", ${welesPrefs.window.oh});`,
    `user_pref("weles.fingerprint.window.screen_x", ${welesPrefs.window.x});`,
    `user_pref("weles.fingerprint.window.screen_y", ${welesPrefs.window.y});`,
  ];
  writeFileSync(join(profile, 'user.js'), prefLines.join('\n'));

  let ff = null;
  const got = await new Promise((resolve) => {
    const server = createServer((req, res) => {
      if (req.method === 'POST' && req.url === '/r') {
        let body = '';
        req.on('data', c => body += c);
        req.on('end', () => {
          res.writeHead(200); res.end('ok');
          try { ff?.kill('SIGKILL'); } catch (_) {}
          server.close();
          resolve(JSON.parse(body));
        });
        return;
      }
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end(`<!doctype html><meta charset="utf-8"><script>(async () => {
        const c = document.createElement('canvas'); c.width = 32; c.height = 32;
        const ctx = c.getContext('2d');
        ctx.fillStyle = '#f60'; ctx.fillRect(0, 0, 32, 32);
        ctx.fillStyle = '#069'; ctx.font = '14px serif'; ctx.fillText('w', 2, 16);
        const canvasLen = c.toDataURL().length;
        const gl = document.createElement('canvas').getContext('webgl');
        let vendor = '', renderer = '';
        try { const e = gl.getExtension('WEBGL_debug_renderer_info');
          vendor = gl.getParameter(e.UNMASKED_VENDOR_WEBGL);
          renderer = gl.getParameter(e.UNMASKED_RENDERER_WEBGL); } catch (_) {}
        await fetch('/r', { method: 'POST', body: JSON.stringify({
          webdriver: navigator.webdriver, webglVendor: vendor, webglRenderer: renderer,
          ua: navigator.userAgent, platform: navigator.platform,
          hwc: navigator.hardwareConcurrency, dm: navigator.deviceMemory,
          screenW: screen.width, screenH: screen.height, screenAW: screen.availWidth, screenAH: screen.availHeight,
          outerW: window.outerWidth, outerH: window.outerHeight, screenX: window.screenX, screenY: window.screenY,
          canvasLen,
        }) });
      })();</script>`);
    });
    server.listen(0, '127.0.0.1', () => {
      ff = spawn(binary, ['-profile', profile, '-no-remote', '--headless', `http://127.0.0.1:${server.address().port}/`], { stdio: 'ignore' });
    });
  });
  rmSync(profile, { recursive: true, force: true });
  return got;
}

console.log(`patched: ${patched}`);
console.log(`stock  : ${stock}`);
console.log('capturing patched ...');
const p = await capture(patched);
console.log('capturing stock   ...');
const s = await capture(stock);

const rows = [
  ['navigator.webdriver',  p.webdriver,     s.webdriver],
  ['webgl vendor',         p.webglVendor,   s.webglVendor],
  ['webgl renderer',       p.webglRenderer, s.webglRenderer],
  ['navigator.platform',   p.platform,      s.platform],
  ['hardwareConcurrency',  p.hwc,           s.hwc],
  ['deviceMemory',         p.dm,            s.dm],
  ['screen.width',         p.screenW,       s.screenW],
  ['screen.height',        p.screenH,       s.screenH],
  ['screen.availWidth',    p.screenAW,      s.screenAW],
  ['screen.availHeight',   p.screenAH,      s.screenAH],
  ['window.outerWidth',    p.outerW,        s.outerW],
  ['window.outerHeight',   p.outerH,        s.outerH],
  ['window.screenX',       p.screenX,       s.screenX],
  ['window.screenY',       p.screenY,       s.screenY],
  ['canvas toDataURL.len', p.canvasLen,     s.canvasLen],
];
console.log('');
console.log('surface'.padEnd(24) + 'patched'.padEnd(34) + 'stock');
console.log('-'.repeat(90));
for (const [name, pv, sv] of rows) {
  const tag = String(pv) === String(sv) ? '    ' : 'DIFF';
  console.log(`${tag} ${name.padEnd(22)}${String(pv).slice(0,32).padEnd(34)}${String(sv).slice(0,40)}`);
}
