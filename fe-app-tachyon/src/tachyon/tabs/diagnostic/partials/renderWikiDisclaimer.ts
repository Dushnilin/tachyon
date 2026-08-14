import { renderBookOpenTextIcon24 } from '../../../../icons';
import { renderButton } from '../../../../partials';
import { insertIf } from '../../../../helpers';

export function renderWikiDisclaimer(kind: 'default' | 'error' | 'warning') {
  const className = [
    'tachyon_wiki-box',
    ...insertIf(kind === 'error', ['tachyon_wiki-box--error']),
    ...insertIf(kind === 'warning', ['tachyon_wiki-box--warning']),
  ].join(' ');

  return E('div', { class: className }, [
    E('div', { class: 'tachyon_wiki-box__content' }, [
      E('span', {}, renderBookOpenTextIcon24()),
      E('div', {}, [
        E('b', {}, _('Troubleshooting')),
        E('div', { style: 'font-size: 13px; margin-top: 4px;' }, _('Do not panic, everything can be fixed, just...')),
      ]),
    ]),
    renderButton({
      classNames: ['cbi-button cbi-button-save'],
      text: _('Open Project Page'),
      onClick: () =>
        window.open(
          'https://github.com/Dushnilin/tachyon#readme',
          '_blank',
          'noopener,noreferrer',
        ),
    }),
  ]);
}
