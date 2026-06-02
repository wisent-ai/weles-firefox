// Post-build verification via local HTTP round-trip. Launches our built
// Firefox directly (no Playwright juggler required) with a profile that
// sets the weles.fingerprint.* prefs; Firefox hits a tiny local server that
// serves a test page; the page JS reads each surface and POSTs the result
// back; the server prints OK/FAIL per surface and exits.

import { existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';

const BIN_CANDIDATES = [
  'mozilla-central/obj-weles/dist/Nightly.app/Contents/MacOS/firefox',
  'mozilla-central/obj-weles/dist/bin/firefox',
];
const bin = process.env.WELES_FIREFOX_BIN || BIN_CANDIDATES.map(p => join(process.cwd(), p)).find(existsSync);
if (!bin) { console.error('FAIL: built binary not found'); process.exit(1); }
console.log(`binary: ${bin}`);

const expected = {
  webglVendor: 'Apple Inc. (weles test)',
  webglRenderer: 'Apple M9 Ultra (weles test)',
  screenW: 2048, screenH: 1536, screenAW: 2048, screenAH: 1500,
  outerW: 2050, outerH: 1616, screenX: 42, screenY: 24,
};

const profile = mkdtempSync(join(tmpdir(), 'weles-verify-'));
writeFileSync(join(profile, 'user.js'), `
user_pref("weles.fingerprint.webdriver.force", true);
user_pref("weles.fingerprint.webgl.vendor", "${expected.webglVendor}");
user_pref("weles.fingerprint.webgl.renderer", "${expected.webglRenderer}");
user_pref("weles.fingerprint.screen.width", ${expected.screenW});
user_pref("weles.fingerprint.screen.height", ${expected.screenH});
user_pref("weles.fingerprint.screen.avail_width", ${expected.screenAW});
user_pref("weles.fingerprint.screen.avail_height", ${expected.screenAH});
user_pref("weles.fingerprint.window.outer_width", ${expected.outerW});
user_pref("weles.fingerprint.window.outer_height", ${expected.outerH});
user_pref("weles.fingerprint.window.screen_x", ${expected.screenX});
user_pref("weles.fingerprint.window.screen_y", ${expected.screenY});
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.page", 0);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("datareporting.policy.firstRunURL", "");
`);

let ffProc = null;
const result = await new Promise((resolve) => {
  const server = createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/r') {
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        res.writeHead(200, { 'content-type': 'text/plain' }); res.end('ok');
        try { ffProc?.kill('SIGKILL'); } catch (_) {}
        server.close();
        resolve(JSON.parse(body));
      });
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(`<!doctype html><meta charset="utf-8"><script>(async () => {
      const c = document.createElement('canvas'); c.width = 16; c.height = 16;
      const gl = c.getContext('webgl');
      let vendor='', renderer='';
      try { const ext = gl.getExtension('WEBGL_debug_renderer_info');
        vendor = gl.getParameter(ext.UNMASKED_VENDOR_WEBGL);
        renderer = gl.getParameter(ext.UNMASKED_RENDERER_WEBGL); } catch (_) {}
      await fetch('/r', { method: 'POST', body: JSON.stringify({
        webdriver: navigator.webdriver, webglVendor: vendor, webglRenderer: renderer,
        screenW: screen.width, screenH: screen.height, screenAW: screen.availWidth, screenAH: screen.availHeight,
        outerW: window.outerWidth, outerH: window.outerHeight, screenX: window.screenX, screenY: window.screenY,
      }) });
    })();</script>ok`);
  });
  server.listen(0, '127.0.0.1', () => {
    const port = server.address().port;
    ffProc = spawn(bin, ['-profile', profile, '-no-remote', '--headless', `http://127.0.0.1:${port}/`], { stdio: 'ignore' });
  });
});

rmSync(profile, { recursive: true, force: true });

const cases = [
  ['patch 2 (webdriver)',      result.webdriver,     false],
  ['patch 3 (webgl vendor)',   result.webglVendor,   expected.webglVendor],
  ['patch 3 (webgl renderer)', result.webglRenderer, expected.webglRenderer],
  ['patch 4 (screen.width)',   result.screenW,       expected.screenW],
  ['patch 4 (screen.height)',  result.screenH,       expected.screenH],
  ['patch 4 (avail_width)',    result.screenAW,      expected.screenAW],
  ['patch 4 (avail_height)',   result.screenAH,      expected.screenAH],
  ['patch 5 (outer_width)',    result.outerW,        expected.outerW],
  ['patch 5 (outer_height)',   result.outerH,        expected.outerH],
  ['patch 5 (screen_x)',       result.screenX,       expected.screenX],
  ['patch 5 (screen_y)',       result.screenY,       expected.screenY],
];
let failed = 0;
console.log('surface'.padEnd(32) + 'want'.padEnd(30) + 'got');
console.log('-'.repeat(90));
for (const [name, got, want] of cases) {
  const ok = String(got) === String(want);
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${name.padEnd(28)}${String(want).slice(0,28).padEnd(30)}${String(got).slice(0,40)}`);
  if (!ok) failed++;
}
process.exit(failed);
