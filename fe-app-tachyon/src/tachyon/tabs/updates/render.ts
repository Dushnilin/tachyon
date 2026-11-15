export function render() {
  return E('div', { id: 'updates-status', class: 'tachyon_updates-page' }, [
    E('div', {
      id: 'tachyon_updates-components',
      class: 'tachyon_updates-page__components',
    }),
  ]);
}
