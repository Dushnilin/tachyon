export function render() {
  return E(
    'div',
    { id: 'diagnostic-status', class: 'tachyon_diagnostic-page' },
    [
      E('div', { class: 'tachyon_diagnostic-page__top-bar' }, [
        E('div', { id: 'tachyon_diagnostic-page-run-check' }),
      ]),
      E('div', { class: 'tachyon_diagnostic-page__main' }, [
        E('div', { class: 'tachyon_diagnostic-page__left' }, [
          E('div', {
            class: 'cbi-section cbi-section-table',
            id: 'tachyon_diagnostic-page-checks',
          }),
        ]),
        E('div', { class: 'tachyon_diagnostic-page__right' }, [
          E('div', { id: 'tachyon_diagnostic-page-wiki' }),
          E('div', { class: 'cbi-section', id: 'tachyon_diagnostic-page-actions' }),
          E('div', { class: 'cbi-section', id: 'tachyon_diagnostic-page-system-info' }),
        ]),
      ]),
    ],
  );
}
