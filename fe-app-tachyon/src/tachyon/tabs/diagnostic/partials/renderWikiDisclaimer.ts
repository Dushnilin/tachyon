import {
  renderBookOpenTextIcon24,
  renderHeartIcon24,
  renderSendIcon24,
} from '../../../../icons';
import { renderButton } from '../../../../partials';
import { insertIf } from '../../../../helpers';
import { tr } from '../../../helpers/i18n';
import { renderSupportModal } from './renderSupportModal';

export function renderWikiDisclaimer(kind: 'default' | 'error' | 'warning') {
  const iconWrap = E('span', {
    class: 'tachyon_diagnostic-page__right-bar__wiki__icon',
  });
  iconWrap.appendChild(renderBookOpenTextIcon24());

  const className = [
    'tachyon_diagnostic-page__right-bar__wiki',
    ...insertIf(kind === 'error', [
      'tachyon_diagnostic-page__right-bar__wiki--error',
    ]),
    ...insertIf(kind === 'warning', [
      'tachyon_diagnostic-page__right-bar__wiki--warning',
    ]),
  ].join(' ');

  return E('section', { class: className }, [
    E(
      'header',
      { class: 'tachyon_diagnostic-page__right-bar__wiki__content' },
      [
        E('div', { class: 'tachyon_diagnostic-page__right-bar__wiki__texts' }, [
          iconWrap,
          E(
            'b',
            {},
            tr(
              'Документация и ресурсы проекта',
              'Documentation & Project Links',
            ),
          ),
        ]),
        E(
          'span',
          { class: 'tachyon_diagnostic-page__right-bar__wiki__meta' },
          'DOCS · REPO',
        ),
      ],
    ),
    renderButton({
      classNames: ['tachyon_diagnostic-wiki-btn'],
      text: _('Open Project Page'),
      onClick: () =>
        window.open(
          'https://github.com/Dushnilin/tachyon#readme',
          '_blank',
          'noopener,noreferrer',
        ),
    }),
    renderButton({
      classNames: ['tachyon_diagnostic-wiki-btn'],
      icon: renderSendIcon24,
      text: _('Telegram Channel'),
      onClick: () =>
        window.open(
          'https://t.me/tachyon_proxy',
          '_blank',
          'noopener,noreferrer',
        ),
    }),
    renderButton({
      classNames: [
        'tachyon_diagnostic-wiki-btn',
        'tachyon_diagnostic-wiki-btn--support',
      ],
      icon: renderHeartIcon24,
      text: _('Support Development'),
      onClick: () => renderSupportModal(),
    }),
  ]);
}
