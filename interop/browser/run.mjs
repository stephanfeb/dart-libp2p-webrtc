// Browser driver for test/interop/browser_interop_test.dart.
//
// Launches a browser, prints READY, then opens one page per URL read from
// stdin. Page console output is forwarded to stdout. Exits when stdin closes.
//
//   BROWSER=chrome|chromium|firefox|webkit (default chrome = installed Chrome)
import { createInterface } from 'node:readline';
import { chromium, firefox, webkit } from 'playwright';

const which = process.env.BROWSER ?? 'chrome';
const browser = await (which === 'firefox'
  ? firefox.launch()
  : which === 'webkit'
    ? webkit.launch()
    : chromium.launch({ channel: which === 'chrome' ? 'chrome' : undefined }));

console.log(`READY ${which} ${browser.version()}`);

const lines = createInterface({ input: process.stdin });
for await (const url of lines) {
  if (!url.trim()) continue;
  const page = await browser.newPage();
  const tag = new URL(url).searchParams.get('scenario');
  page.on('console', (m) => console.log(`[${tag}] ${m.text()}`));
  page.on('pageerror', (e) => console.log(`[${tag}] pageerror: ${e.message}`));
  await page.goto(url);
}
await browser.close();
