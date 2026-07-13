export function render() {
  return E(
    'div',
    { id: 'diagnostic-status', class: 'tachyon_diagnostic-page' },
    [
      E('div', { class: 'tachyon_diagnostic-page__left-bar' }, [
        E('div', { id: 'tachyon_diagnostic-page-run-check' }),
        E('div', {
          class: 'tachyon_diagnostic-page__checks',
          id: 'tachyon_diagnostic-page-checks',
        }),
      ]),
      E('div', { class: 'tachyon_diagnostic-page__right-bar' }, [
        E('div', { id: 'tachyon_diagnostic-page-wiki' }),
        E('div', { id: 'tachyon_diagnostic-page-actions' }),
        E('div', { id: 'tachyon_diagnostic-page-system-info' }),
      ]),
    ],
  );
}
