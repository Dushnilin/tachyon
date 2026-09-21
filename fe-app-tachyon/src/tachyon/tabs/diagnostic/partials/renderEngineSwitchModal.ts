import { TachyonShellMethods } from '../../../methods/shell';
import { renderButton } from '../../../../partials';
import { engineLabel, parkedFeatures } from '../../../helpers/engine';

/**
 * Engine switcher. Shows the active routing engine, the engines that are
 * installed or installable, and — before a switch — the configuration that the
 * target engine cannot express. Those features are parked by the backend, not
 * dropped, so the dialog states what becomes unavailable rather than hiding it.
 */
export function renderEngineSwitchModal() {
  const switching = false;

  const statusLabel = E(
    'div',
    {
      style:
        'font-size: 13px; font-weight: 500; margin-bottom: 10px; color: var(--text-color-medium, #6c757d);',
    },
    _('Loading engine information...'),
  );

  const enginesContainer = E('div', {
    style: 'display: flex; flex-direction: column; gap: 8px;',
  });

  const warningsContainer = E('div', {
    style:
      'margin-top: 12px; font-size: 12px; color: var(--text-color-medium, #b58900); display: none;',
  });

  const closeBtn = renderButton({
    text: _('Close'),
    classNames: ['cbi-button-neutral'],
    onClick: () => {
      if (ui.hideModal) ui.hideModal();
    },
  });

  const refresh = async () => {
    const response = await TachyonShellMethods.getEngineInfo();
    if (!response.success) {
      statusLabel.textContent = _('Failed to load engine information.');
      return;
    }
    const info = response.data;
    if (!info || !Array.isArray(info.engines)) {
      statusLabel.textContent = _('Failed to load engine information.');
      return;
    }

    statusLabel.textContent = `${_('Active engine')}: ${engineLabel(info.active)}`;
    enginesContainer.textContent = '';

    for (const entry of info.engines) {
      if (!entry.known) {
        continue;
      }
      const isActive = entry.engine === info.active;
      const row = E(
        'div',
        {
          style:
            'display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 8px 10px; border: 1px solid var(--border-color, rgba(255,255,255,0.1)); border-radius: 6px;',
        },
        [
          E('div', { style: 'display: flex; flex-direction: column;' }, [
            E(
              'span',
              { style: 'font-weight: 600;' },
              engineLabel(entry.engine),
            ),
            E(
              'span',
              { style: 'font-size: 11px; opacity: 0.7;' },
              entry.installed ? _('installed') : _('not installed'),
            ),
          ]),
        ],
      );

      if (isActive) {
        row.appendChild(
          E('span', { style: 'font-size: 12px; opacity: 0.8;' }, _('active')),
        );
      } else {
        row.appendChild(
          renderButton({
            text: _('Switch'),
            classNames: ['cbi-button-action'],
            disabled: switching,
            onClick: () => switchTo(entry.engine, info.active),
          }),
        );
      }

      enginesContainer.appendChild(row);
    }
  };

  const switchTo = async (engine: string, _from: string) => {
    if (switching) {
      return;
    }

    const planResponse = await TachyonShellMethods.getEnginePlan(engine);
    const plan = planResponse.success ? planResponse.data : null;
    const parked = parkedFeatures(plan);
    if (parked.length > 0) {
      warningsContainer.style.display = 'block';
      warningsContainer.textContent = `${_('These features will be parked and restored when you switch back')}: ${parked.join(', ')}`;
    } else {
      warningsContainer.style.display = 'none';
    }

    const result = await TachyonShellMethods.switchEngine(engine, true);
    if (!result.success || !result.data.ok) {
      warningsContainer.style.display = 'block';
      warningsContainer.textContent = `${_('Switch failed')}: ${result.success ? result.data.reason : result.error}`;
      return;
    }

    await refresh();
    ui.addNotification(
      _('Tachyon'),
      E('p', {}, `${_('Active engine')}: ${engineLabel(engine)}`),
    );
  };

  const modalContent = E('div', { style: 'padding: 8px;' }, [
    E(
      'p',
      { style: 'font-size: 13px; opacity: 0.85; margin-bottom: 12px;' },
      _(
        'Tachyon can drive more than one routing engine. Switching preserves configuration the target engine cannot express, so you can switch back without losing settings.',
      ),
    ),
    statusLabel,
    enginesContainer,
    warningsContainer,
    E(
      'div',
      {
        style:
          'display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; border-top: 1px solid var(--border-color, rgba(255,255,255,0.1)); padding-top: 12px;',
      },
      [closeBtn],
    ),
  ]);

  ui.showModal(`⚙️ ${_('Routing Engine')}`, modalContent);
  void refresh();
}
