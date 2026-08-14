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
import { IDiagnosticsChecksStoreItem } from '../../../services';

type IRenderCheckSectionProps = IDiagnosticsChecksStoreItem;

function renderCheckSummary(items: IRenderCheckSectionProps['items']) {
  if (!items.length) {
    return E('div', {}, '');
  }

  const renderedItems = items.map((item) => {
    function getIcon() {
      if (item.state === 'success') return renderCheckIcon24();
      if (item.state === 'warning') return renderTriangleAlertIcon24();
      if (item.state === 'error') return renderXIcon24();
      return E('span', {}, '');
    }

    return E(
      'div',
      { class: `tachyon_check-row__summary__item tachyon_check-row__summary__item--${item.state}` },
      [E('span', {}, getIcon()), E('b', {}, item.key), E('span', {}, item.value)],
    );
  });

  return E('div', { class: 'tachyon_check-row__summary' }, renderedItems);
}

function renderIcon(state: string) {
  const wrap = E('span', { class: 'tachyon_check-row__icon' });
  if (state === 'loading') wrap.appendChild(renderLoaderCircleIcon24());
  else if (state === 'warning') wrap.appendChild(renderCircleAlertIcon24());
  else if (state === 'error') wrap.appendChild(renderCircleXIcon24());
  else if (state === 'success') wrap.appendChild(renderCircleCheckIcon24());
  else if (state === 'skipped') wrap.appendChild(renderCircleSlashIcon24());
  return wrap;
}

export function renderCheckSection(props: IRenderCheckSectionProps) {
  return E(
    'div',
    { class: `tachyon_check-row tachyon_check-row--${props.state}` },
    [
      renderIcon(props.state),
      E('div', { class: 'tachyon_check-row__body' }, [
        E('b', { class: 'tachyon_check-row__title' }, props.title),
        E('span', { class: 'tachyon_check-row__detail' }, props.description),
        renderCheckSummary(props.items),
      ]),
    ],
  );
}
