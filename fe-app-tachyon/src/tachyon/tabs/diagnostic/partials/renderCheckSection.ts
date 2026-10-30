import {
  renderCheckIcon24,
  renderCircleAlertIcon24,
  renderCircleCheckIcon24,
  renderCircleSlashIcon24,
  renderCircleXIcon24,
  renderLoaderCircleIcon24,
  renderTriangleAlertIcon24,
  renderXIcon24,
} from '../../../../icons';
import { tr } from '../../../helpers/i18n';
import { IDiagnosticsChecksStoreItem } from '../../../services';

type IRenderCheckSectionProps = IDiagnosticsChecksStoreItem;

const expandedCheckCards = new Set<string>();

export function clearExpandedCheckCards() {
  expandedCheckCards.clear();
}

function renderCheckSummary(
  code: string,
  items: IRenderCheckSectionProps['items'],
) {
  if (!items.length) {
    return E('div', { class: 'tachyon_diagnostic_alert__summary' });
  }

  const isExpanded = expandedCheckCards.has(code);

  const renderedItems = items.map((item) => {
    function getIcon() {
      const iconWrap = E('span', {
        class: 'tachyon_diagnostic_alert__summary__item__icon',
      });

      if (item.state === 'success') {
        iconWrap.appendChild(renderCheckIcon24());
      }

      if (item.state === 'warning') {
        iconWrap.appendChild(renderTriangleAlertIcon24());
      }

      if (item.state === 'error') {
        iconWrap.appendChild(renderXIcon24());
      }

      return iconWrap;
    }

    return E(
      'div',
      {
        class: `tachyon_diagnostic_alert__summary__item tachyon_diagnostic_alert__summary__item--${item.state}`,
      },
      [getIcon(), E('b', {}, item.key), E('div', {}, item.value)],
    );
  });

  return E(
    'div',
    {
      class: `tachyon_diagnostic_alert__summary${
        isExpanded ? ' tachyon_diagnostic_alert__summary--expanded' : ''
      }`,
    },
    renderedItems,
  );
}

function attachCardExpandHandler(
  card: HTMLElement,
  props: IRenderCheckSectionProps,
) {
  if (
    !props.items.length ||
    props.state === 'loading' ||
    props.state === 'skipped'
  ) {
    return card;
  }

  const isExpanded = expandedCheckCards.has(props.code);
  card.classList.add('tachyon_diagnostic_alert--collapsible');
  if (isExpanded) {
    card.classList.add('tachyon_diagnostic_alert--expanded');
  }

  const contentEl = card.querySelector('.tachyon_diagnostic_alert__content');
  if (contentEl) {
    const toggleHint = E(
      'span',
      { class: 'tachyon_diagnostic_alert__toggle-hint' },
      isExpanded
        ? `${tr('Скрыть подробности', 'Hide details')} (${props.items.length}) ▴`
        : `${tr('Показать подробности', 'Show details')} (${props.items.length}) ▾`,
    );
    contentEl.appendChild(toggleHint);
  }

  card.addEventListener('click', () => {
    const summaryEl = card.querySelector('.tachyon_diagnostic_alert__summary');
    const hintEl = card.querySelector('.tachyon_diagnostic_alert__toggle-hint');
    const nextExpanded = !expandedCheckCards.has(props.code);
    if (nextExpanded) {
      expandedCheckCards.add(props.code);
      card.classList.add('tachyon_diagnostic_alert--expanded');
      summaryEl?.classList.add('tachyon_diagnostic_alert__summary--expanded');
      if (hintEl) {
        hintEl.textContent = `${tr('Скрыть подробности', 'Hide details')} (${props.items.length}) ▴`;
      }
    } else {
      expandedCheckCards.delete(props.code);
      card.classList.remove('tachyon_diagnostic_alert--expanded');
      summaryEl?.classList.remove(
        'tachyon_diagnostic_alert__summary--expanded',
      );
      if (hintEl) {
        hintEl.textContent = `${tr('Показать подробности', 'Show details')} (${props.items.length}) ▾`;
      }
    }
  });

  return card;
}

function renderLoadingState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'tachyon_diagnostic_alert__icon' });
  iconWrap.appendChild(renderLoaderCircleIcon24());

  return E(
    'div',
    { class: 'tachyon_diagnostic_alert tachyon_diagnostic_alert--loading' },
    [
      iconWrap,
      E('div', { class: 'tachyon_diagnostic_alert__content' }, [
        E('b', { class: 'tachyon_diagnostic_alert__title' }, props.title),
        E(
          'div',
          { class: 'tachyon_diagnostic_alert__description' },
          props.description,
        ),
      ]),
      renderCheckSummary(props.code, props.items),
    ],
  );
}

function renderWarningState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'tachyon_diagnostic_alert__icon' });
  iconWrap.appendChild(renderCircleAlertIcon24());

  return attachCardExpandHandler(
    E(
      'div',
      { class: 'tachyon_diagnostic_alert tachyon_diagnostic_alert--warning' },
      [
        iconWrap,
        E('div', { class: 'tachyon_diagnostic_alert__content' }, [
          E('b', { class: 'tachyon_diagnostic_alert__title' }, props.title),
          E(
            'div',
            { class: 'tachyon_diagnostic_alert__description' },
            props.description,
          ),
        ]),
        renderCheckSummary(props.code, props.items),
      ],
    ),
    props,
  );
}

function renderErrorState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'tachyon_diagnostic_alert__icon' });
  iconWrap.appendChild(renderCircleXIcon24());

  return attachCardExpandHandler(
    E(
      'div',
      { class: 'tachyon_diagnostic_alert tachyon_diagnostic_alert--error' },
      [
        iconWrap,
        E('div', { class: 'tachyon_diagnostic_alert__content' }, [
          E('b', { class: 'tachyon_diagnostic_alert__title' }, props.title),
          E(
            'div',
            { class: 'tachyon_diagnostic_alert__description' },
            props.description,
          ),
        ]),
        renderCheckSummary(props.code, props.items),
      ],
    ),
    props,
  );
}

function renderSuccessState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'tachyon_diagnostic_alert__icon' });
  iconWrap.appendChild(renderCircleCheckIcon24());

  return attachCardExpandHandler(
    E(
      'div',
      { class: 'tachyon_diagnostic_alert tachyon_diagnostic_alert--success' },
      [
        iconWrap,
        E('div', { class: 'tachyon_diagnostic_alert__content' }, [
          E('b', { class: 'tachyon_diagnostic_alert__title' }, props.title),
          E(
            'div',
            { class: 'tachyon_diagnostic_alert__description' },
            props.description,
          ),
        ]),
        renderCheckSummary(props.code, props.items),
      ],
    ),
    props,
  );
}

function renderSkippedState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'tachyon_diagnostic_alert__icon' });
  iconWrap.appendChild(renderCircleSlashIcon24());

  return E(
    'div',
    { class: 'tachyon_diagnostic_alert tachyon_diagnostic_alert--skipped' },
    [
      iconWrap,
      E('div', { class: 'tachyon_diagnostic_alert__content' }, [
        E('b', { class: 'tachyon_diagnostic_alert__title' }, props.title),
        E(
          'div',
          { class: 'tachyon_diagnostic_alert__description' },
          props.description,
        ),
      ]),
      renderCheckSummary(props.code, props.items),
    ],
  );
}

export function renderCheckSection(props: IRenderCheckSectionProps) {
  if (props.state === 'loading') {
    return renderLoadingState(props);
  }

  if (props.state === 'warning') {
    return renderWarningState(props);
  }

  if (props.state === 'error') {
    return renderErrorState(props);
  }

  if (props.state === 'success') {
    return renderSuccessState(props);
  }

  if (props.state === 'skipped') {
    return renderSkippedState(props);
  }

  return E('div', {}, _('Not implement yet'));
}
