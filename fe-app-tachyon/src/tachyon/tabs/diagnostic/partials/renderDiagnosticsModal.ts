import { renderButton } from '../../../../partials';
import {
  renderActivityIcon,
  renderAlertTriangleIcon,
  renderCircleCheckBigIcon24,
  renderCircleXIcon24,
  renderCopyIcon24,
  renderHourglassIcon,
  renderRotateCcwIcon24,
  renderWrenchIcon,
} from '../../../../icons';
import { copyToClipboard } from '../../../../helpers/copyToClipboard';
import { tr } from '../../../helpers/i18n';
import { IDiagnosticsChecksStoreItem, store } from '../../../services';
import {
  areAllCheckCardsExpanded,
  collapseHealthyCheckCards,
  expandAllCheckCards,
  renderCheckSection,
} from './renderCheckSection';

export interface RenderDiagnosticsModalOptions {
  onRunChecks: () => void;
  onRunDoctor?: (fix?: boolean) => void;
  onRunAiDoctor?: () => void;
}

let activeModalRoot: HTMLElement | null = null;
let lastModalOptions: RenderDiagnosticsModalOptions | null = null;

function getUi(): {
  showModal?: (title: string, children: HTMLElement | Node[]) => void;
  hideModal?: () => void;
} | null {
  if (typeof ui !== 'undefined' && ui) return ui;
  if (
    typeof globalThis !== 'undefined' &&
    (globalThis as Record<string, unknown>).ui
  ) {
    return (globalThis as Record<string, unknown>).ui as {
      showModal?: (title: string, children: HTMLElement | Node[]) => void;
      hideModal?: () => void;
    };
  }
  return null;
}

function buildPlainTextReport(checks: IDiagnosticsChecksStoreItem[]): string {
  const sys = store.get().diagnosticsSystemInfo;
  const lines: string[] = [
    `=== Tachyon Diagnostics Report ===`,
    `Version: ${sys.tachyon_version || 'unknown'} | Engine: ${
      sys.sing_box_tachyon_core ? 'tachyon-core' : 'sing-box'
    } (${sys.sing_box_version || 'unknown'})`,
    `OS: ${sys.openwrt_version || 'unknown'} | Device: ${sys.device_model || 'unknown'}`,
    '',
  ];

  for (const check of checks) {
    lines.push(
      `[${check.state.toUpperCase()}] ${check.title} — ${check.description}`,
    );
    for (const item of check.items) {
      const icon =
        item.state === 'success'
          ? 'OK'
          : item.state === 'warning'
            ? 'WARN'
            : 'FAIL';
      lines.push(
        `  - [${icon}] ${item.key}${item.value ? `: ${item.value}` : ''}`,
      );
    }
    lines.push('');
  }

  return lines.join('\n').trim();
}

function renderModalBodyContent(
  root: HTMLElement,
  options: RenderDiagnosticsModalOptions,
) {
  const checks = [...store.get().diagnosticsChecks].sort(
    (a, b) => a.order - b.order,
  );
  const isRunning = Boolean(store.get().diagnosticsRunAction.loading);
  const totalCount = checks.length;
  const completedCount = checks.filter(
    (c) => c.state !== 'skipped' && c.state !== 'loading',
  ).length;
  const loadingCheck = checks.find((c) => c.state === 'loading');
  const passedCount = checks.filter((c) => c.state === 'success').length;
  const warnCount = checks.filter((c) => c.state === 'warning').length;
  const errorCount = checks.filter((c) => c.state === 'error').length;

  const progressPct =
    totalCount > 0
      ? isRunning
        ? Math.max(8, Math.round((completedCount / totalCount) * 100))
        : 100
      : 0;

  let bannerState: 'loading' | 'success' | 'warning' | 'error' = 'success';
  if (isRunning) {
    bannerState = 'loading';
  } else if (errorCount > 0) {
    bannerState = 'error';
  } else if (warnCount > 0) {
    bannerState = 'warning';
  }

  const summaryIcon = isRunning
    ? renderHourglassIcon(18)
    : bannerState === 'success'
      ? renderCircleCheckBigIcon24()
      : bannerState === 'warning'
        ? renderAlertTriangleIcon(18)
        : renderCircleXIcon24();

  const summaryTitle = isRunning
    ? `${tr('Выполняется диагностика подсистем', 'Running subsystem diagnostics')}: ${completedCount} / ${totalCount}`
    : errorCount > 0
      ? `${tr('Обнаружены ошибки в подсистемах', 'Subsystem errors detected')} (${errorCount})`
      : warnCount > 0
        ? `${tr('Диагностика завершена с предупреждениями', 'Diagnostics finished with warnings')} (${warnCount})`
        : `${tr('Все подсистемы работают исправно', 'All subsystems are healthy')} (${passedCount} / ${totalCount})`;

  const summarySubtitle = isRunning
    ? loadingCheck
      ? `${tr('Проверяется', 'Checking')}: ${loadingCheck.title}...`
      : tr('Пожалуйста, подождите...', 'Please wait...')
    : [
        `${tr('Успешно', 'Passed')}: ${passedCount}`,
        `${tr('Предупреждений', 'Warnings')}: ${warnCount}`,
        `${tr('Ошибок', 'Errors')}: ${errorCount}`,
      ].join(' · ');

  const allExpanded = areAllCheckCardsExpanded(checks);

  const toggleAllBtn = renderButton({
    classNames: ['cbi-button-neutral'],
    text: allExpanded
      ? tr('Свернуть без ошибок', 'Collapse non-errors')
      : tr('Развернуть все', 'Expand all'),
    disabled: isRunning || completedCount === 0,
    onClick: () => {
      if (areAllCheckCardsExpanded(checks)) {
        collapseHealthyCheckCards(checks);
      } else {
        expandAllCheckCards(checks.map((c) => c.code));
      }
      renderModalBodyContent(root, options);
    },
  });

  const copyReportBtn = renderButton({
    classNames: ['cbi-button-neutral'],
    icon: renderCopyIcon24,
    text: tr('Скопировать отчёт', 'Copy report'),
    disabled: isRunning || completedCount === 0,
    onClick: () => {
      copyToClipboard(buildPlainTextReport(checks));
    },
  });

  const toolbarActions: HTMLElement[] = [toggleAllBtn, copyReportBtn];

  if (!isRunning && (errorCount > 0 || warnCount > 0) && options.onRunDoctor) {
    toolbarActions.push(
      renderButton({
        classNames: ['cbi-button-action'],
        icon: () => renderWrenchIcon(16),
        text: tr('Запустить восстановление', 'Run doctor repair'),
        onClick: () => {
          getUi()?.hideModal?.();
          options.onRunDoctor?.(false);
        },
      }),
    );
  }

  const headerBanner = E(
    'div',
    {
      class: `tachyon_diagnostic-summary-banner tachyon_diagnostic-summary-banner--${bannerState}`,
    },
    [
      E('div', { class: 'tachyon_diagnostic-summary-banner__main' }, [
        E('b', { class: 'tachyon_diagnostic-summary-banner__title' }, [
          summaryIcon,
          E('span', {}, summaryTitle),
        ]),
        E(
          'span',
          { class: 'tachyon_diagnostic-summary-banner__subtitle' },
          summarySubtitle,
        ),
      ]),
      E('div', { class: 'tachyon_diagnostic-modal__toolbar' }, toolbarActions),
    ],
  );

  const progressTrack = E(
    'div',
    {
      class: 'tachyon_diagnostic-modal__progress-track',
      style: isRunning ? '' : 'display:none;',
    },
    [
      E('div', {
        class: 'tachyon_diagnostic-modal__progress-bar',
        style: `width: ${progressPct}%;`,
      }),
    ],
  );

  // Sort checks so errors and warnings appear at the top once completed,
  // or keep natural order while running so cards don't jump around mid-flight.
  const orderedChecks = isRunning
    ? checks
    : [...checks].sort((a, b) => {
        const rank = (s: IDiagnosticsChecksStoreItem['state']) =>
          s === 'error' ? 0 : s === 'warning' ? 1 : s === 'loading' ? 2 : 3;
        const diff = rank(a.state) - rank(b.state);
        return diff !== 0 ? diff : a.order - b.order;
      });

  const checksGrid = E(
    'div',
    {
      class:
        'tachyon_diagnostic-page__checks-grid tachyon_diagnostic-modal__checks-grid',
    },
    orderedChecks.map((check) => renderCheckSection(check)),
  );

  const footer = E('div', { class: 'tachyon_diagnostic-modal__footer' }, [
    renderButton({
      classNames: ['cbi-button-apply'],
      icon: renderRotateCcwIcon24,
      text: isRunning
        ? tr('Выполняется проверка...', 'Checking...')
        : tr('Перезапустить диагностику', 'Re-run diagnostics'),
      loading: isRunning,
      disabled: isRunning,
      onClick: () => {
        options.onRunChecks();
      },
    }),
    renderButton({
      classNames: ['cbi-button-neutral'],
      text: _('Close'),
      onClick: () => {
        activeModalRoot = null;
        getUi()?.hideModal?.();
      },
    }),
  ]);

  root.replaceChildren(headerBanner, progressTrack, checksGrid, footer);
}

export function updateDiagnosticsModalIfOpen() {
  if (!activeModalRoot || !activeModalRoot.isConnected || !lastModalOptions) {
    return;
  }
  renderModalBodyContent(activeModalRoot, lastModalOptions);
}

export function renderDiagnosticsModal(options: RenderDiagnosticsModalOptions) {
  const uiInstance = getUi();
  lastModalOptions = options;

  if (activeModalRoot && activeModalRoot.isConnected) {
    renderModalBodyContent(activeModalRoot, options);
    return;
  }

  const root = E('div', { class: 'tachyon_diagnostic-modal' });
  activeModalRoot = root;
  renderModalBodyContent(root, options);

  if (uiInstance?.showModal) {
    uiInstance.showModal(
      tr('Диагностика состояния и подсистем', 'System & Subsystem Diagnostics'),
      [root],
    );
  }
}

export function renderOpenDiagnosticsModalButton(
  onClick: () => void,
): HTMLElement {
  return renderButton({
    classNames: ['cbi-button-neutral'],
    icon: () => renderActivityIcon(16),
    text: tr('Открыть в модальном окне', 'Open in modal'),
    onClick,
  });
}
