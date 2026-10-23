import { describe, it, expect } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

class MockMutationObserver {
  observe() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
}
globalThis.MutationObserver = MockMutationObserver;

globalThis.document = {
  body: {},
  createElement: () => ({}),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
};

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

describe('Viewport and Mobile Responsiveness Regressions', async () => {
  const { styles: dashboardStyles } = await import('../tabs/dashboard/styles');
  const { GlobalStyles } = await import('../../styles');

  it('does not use display: table or table-layout: fixed on the dashboard root', () => {
    expect(dashboardStyles).not.toMatch(
      /\.tachyon_dashboard-page\s*\{[^}]*display:\s*table/,
    );
    expect(dashboardStyles).not.toMatch(/table-layout:\s*fixed/);
    expect(dashboardStyles).toMatch(
      /\.tachyon_dashboard-page\s*\{[^}]*display:\s*block/,
    );
  });

  it('removes rigid desktop min-width limits from dashboard buttons', () => {
    expect(dashboardStyles).not.toMatch(
      /\.tachyon_dashboard-page\s+\.btn\.tachyon_dashboard-page__outbound-section__subscription-update\s*\{[^}]*min-width:\s*130px/,
    );
    expect(dashboardStyles).not.toMatch(
      /\.tachyon_dashboard-page\s+\.btn\.dashboard-sections-grid-item-test-latency\s*\{[^}]*min-width:\s*99px/,
    );
    expect(dashboardStyles).toMatch(
      /\.tachyon_dashboard-page__outbound-section__title-section__actions\s*\{[^}]*flex-wrap:\s*wrap/,
    );
  });

  it('ensures fkp-server-info-modal is fluid and responsive on mobile screens', () => {
    const serverJsPath = path.resolve(
      __dirname,
      '../../../../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/server.js',
    );
    const serverJsContent = fs.readFileSync(serverJsPath, 'utf8');

    expect(serverJsContent).toMatch(
      /\.fkp-server-info-modal\{[^}]*width:\s*100%\s*!important/,
    );
    expect(serverJsContent).toMatch(
      /\.fkp-server-info-modal__qr-image\{[^}]*max-width:\s*min\(180px,\s*60vw\)/,
    );
    expect(serverJsContent).toMatch(
      /@media\s*\(max-width:\s*640px\)\{\s*\.fkp-server-info-modal\{width:100%\s*!important\}/,
    );
  });

  it('scopes responsive CBI table rules to Tachyon selectors', () => {
    expect(GlobalStyles).not.toMatch(
      /@media\s*\(max-width:\s*768px\)\s*\{\s*\.cbi-section-table\s*\{/,
    );
    expect(GlobalStyles).toMatch(/\[id\^="cbi-tachyon"\] \.cbi-section-table/);
  });
});
