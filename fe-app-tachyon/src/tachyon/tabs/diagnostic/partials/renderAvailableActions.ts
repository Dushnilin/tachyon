import { renderButton } from '../../../../partials';
import {
  renderCircleCheckBigIcon24,
  renderCirclePlayIcon24,
  renderCircleStopIcon24,
  renderCogIcon24,
  renderPauseIcon24,
  renderPlayIcon24,
  renderRotateCcwIcon24,
  renderSquareChartGanttIcon24,
  renderDownloadIcon24,
  renderZapIcon,
  renderGlobeIcon,
  renderBotIcon,
  renderWrenchIcon,
} from '../../../../icons';
import { insertIf } from '../../../../helpers';

interface ActionProps {
  loading: boolean;
  visible: boolean;
  disabled: boolean;
  onClick: () => void;
  text?: string;
}

interface IRenderAvailableActionsProps {
  restart: ActionProps;
  start: ActionProps;
  stop: ActionProps;
  enable: ActionProps;
  disable: ActionProps;
  globalCheck: ActionProps;
  doctor: ActionProps;
  aiDoctor: ActionProps;
  aiChat?: ActionProps;
  strategyFuzzer?: ActionProps;
  restoreNativeInternet?: ActionProps;
  viewLogs: ActionProps;
  showSingBoxConfig: ActionProps;
  generateBugReport: ActionProps;
  checkServices: ActionProps;
  testLeaks?: ActionProps;
  routeExplain?: ActionProps;
  stabilityReport?: ActionProps;
}

function renderActionBentoGroup(
  title: string | (string | Node)[],
  subtitle: string,
  buttons: HTMLElement[],
) {
  if (!buttons.length) {
    return null;
  }
  return E('div', { class: 'tachyon_diagnostic-action-group' }, [
    E('div', { class: 'tachyon_diagnostic-action-group__header' }, [
      E(
        'b',
        {
          class: 'tachyon_diagnostic-action-group__title',
          style: 'display:inline-flex;align-items:center;gap:7px;',
        },
        title,
      ),
      E(
        'span',
        { class: 'tachyon_diagnostic-action-group__subtitle' },
        subtitle,
      ),
    ]),
    E('div', { class: 'tachyon_diagnostic-action-group__grid' }, buttons),
  ]);
}

export function renderAvailableActions({
  restart,
  start,
  stop,
  enable,
  disable,
  globalCheck,
  doctor,
  aiDoctor,
  aiChat,
  strategyFuzzer,
  restoreNativeInternet,
  viewLogs,
  showSingBoxConfig,
  generateBugReport,
  checkServices,
  testLeaks,
  routeExplain,
  stabilityReport,
}: IRenderAvailableActionsProps) {
  // 1. Service Control Group
  const serviceButtons: HTMLElement[] = [
    ...insertIf(restart.visible, [
      renderButton({
        classNames: ['cbi-button-apply'],
        onClick: restart.onClick,
        icon: renderRotateCcwIcon24,
        text: _('Restart Tachyon'),
        loading: restart.loading,
        disabled: restart.disabled,
      }),
    ]),
    ...insertIf(stop.visible, [
      renderButton({
        classNames: ['cbi-button-remove'],
        onClick: stop.onClick,
        icon: renderCircleStopIcon24,
        text: _('Stop Tachyon'),
        loading: stop.loading,
        disabled: stop.disabled,
      }),
    ]),
    ...insertIf(start.visible, [
      renderButton({
        classNames: ['cbi-button-save'],
        onClick: start.onClick,
        icon: renderCirclePlayIcon24,
        text: _('Start Tachyon'),
        loading: start.loading,
        disabled: start.disabled,
      }),
    ]),
    ...insertIf(disable.visible, [
      renderButton({
        classNames: ['cbi-button-remove'],
        onClick: disable.onClick,
        icon: renderPauseIcon24,
        text: _('Disable autostart'),
        loading: disable.loading,
        disabled: disable.disabled,
      }),
    ]),
    ...insertIf(enable.visible, [
      renderButton({
        classNames: ['cbi-button-save'],
        onClick: enable.onClick,
        icon: renderPlayIcon24,
        text: _('Enable autostart'),
        loading: enable.loading,
        disabled: enable.disabled,
      }),
    ]),
    ...insertIf(!!restoreNativeInternet?.visible, [
      renderButton({
        classNames: ['cbi-button-reset'],
        onClick: restoreNativeInternet!.onClick,
        icon: renderCircleStopIcon24,
        text: _('Restore Native Internet'),
        loading: restoreNativeInternet!.loading,
        disabled: restoreNativeInternet!.disabled,
      }),
    ]),
  ];

  // 2. Network & Route Verification Group
  const networkButtons: HTMLElement[] = [
    ...insertIf(checkServices.visible, [
      renderButton({
        classNames: ['cbi-button-action'],
        onClick: checkServices.onClick,
        icon: renderSquareChartGanttIcon24,
        text: _('Check Services'),
        loading: checkServices.loading,
        disabled: checkServices.disabled,
      }),
    ]),
    ...insertIf(!!testLeaks?.visible, [
      renderButton({
        classNames: ['cbi-button-action'],
        onClick: testLeaks!.onClick,
        icon: renderCircleCheckBigIcon24,
        text: _('IP & DNS Leak Test'),
        loading: testLeaks!.loading,
        disabled: testLeaks!.disabled,
      }),
    ]),
    ...insertIf(!!routeExplain?.visible, [
      renderButton({
        classNames: ['cbi-button-action'],
        onClick: routeExplain!.onClick,
        icon: renderSquareChartGanttIcon24,
        text: _('Route Decision Explainer'),
        loading: routeExplain!.loading,
        disabled: routeExplain!.disabled,
      }),
    ]),
    ...insertIf(!!stabilityReport?.visible, [
      renderButton({
        classNames: ['cbi-button-action'],
        onClick: stabilityReport!.onClick,
        icon: renderCircleCheckBigIcon24,
        text: _('Stability & Fleet Report'),
        loading: stabilityReport!.loading,
        disabled: stabilityReport!.disabled,
      }),
    ]),
  ];

  // 3. AI & Automated Repair Group
  const aiAndRepairButtons: HTMLElement[] = [
    ...insertIf(aiDoctor.visible, [
      renderButton({
        classNames: ['cbi-button-action'],
        onClick: aiDoctor.onClick,
        icon: renderRotateCcwIcon24,
        text: _('Run AI Doctor'),
        loading: aiDoctor.loading,
        disabled: aiDoctor.disabled,
      }),
    ]),
    ...insertIf(!!aiChat?.visible, [
      renderButton({
        classNames: ['cbi-button-action'],
        onClick: aiChat!.onClick,
        icon: renderCircleCheckBigIcon24,
        text: _('AI Chat Assistant'),
        loading: aiChat!.loading,
        disabled: aiChat!.disabled,
      }),
    ]),
    ...insertIf(doctor.visible, [
      renderButton({
        onClick: doctor.onClick,
        icon: renderRotateCcwIcon24,
        text: _('Run doctor repair'),
        loading: doctor.loading,
        disabled: doctor.disabled,
      }),
    ]),
    ...insertIf(!!strategyFuzzer?.visible, [
      renderButton({
        classNames: ['cbi-button-action'],
        onClick: strategyFuzzer!.onClick,
        icon: renderCirclePlayIcon24,
        text: _('DPI Strategy Fuzzer'),
        loading: strategyFuzzer!.loading,
        disabled: strategyFuzzer!.disabled,
      }),
    ]),
  ];

  // 4. Logs, Config & Reports Group
  const debugButtons: HTMLElement[] = [
    ...insertIf(viewLogs.visible, [
      renderButton({
        onClick: viewLogs.onClick,
        icon: renderSquareChartGanttIcon24,
        text: _('View logs'),
        loading: viewLogs.loading,
        disabled: viewLogs.disabled,
      }),
    ]),
    ...insertIf(showSingBoxConfig.visible, [
      renderButton({
        onClick: showSingBoxConfig.onClick,
        icon: renderCogIcon24,
        text: showSingBoxConfig.text || _('Show sing-box config'),
        loading: showSingBoxConfig.loading,
        disabled: showSingBoxConfig.disabled,
      }),
    ]),
    ...insertIf(globalCheck.visible, [
      renderButton({
        onClick: globalCheck.onClick,
        icon: renderCircleCheckBigIcon24,
        text: _('Get global check'),
        loading: globalCheck.loading,
        disabled: globalCheck.disabled,
      }),
    ]),
    ...insertIf(generateBugReport.visible, [
      renderButton({
        onClick: generateBugReport.onClick,
        icon: renderDownloadIcon24,
        text: _('Generate bug report'),
        loading: generateBugReport.loading,
        disabled: generateBugReport.disabled,
      }),
    ]),
  ];

  const groups = [
    renderActionBentoGroup(
      [renderZapIcon(14), _('Service Control')],
      _('Manage Tachyon daemon lifecycle and emergency bypass'),
      serviceButtons,
    ),
    renderActionBentoGroup(
      [renderGlobeIcon(14), _('Network & Route Verification')],
      _('Test service reachability, leaks, routing rules and node stability'),
      networkButtons,
    ),
    renderActionBentoGroup(
      [renderBotIcon(14), _('AI & Automated Repair')],
      _('Diagnose issues automatically or fuzz DPI bypass strategies'),
      aiAndRepairButtons,
    ),
    renderActionBentoGroup(
      [renderWrenchIcon(14), _('Logs, Config & Reports')],
      _('Inspect live logs, generated engine config and export reports'),
      debugButtons,
    ),
  ].filter(Boolean) as HTMLElement[];

  return E(
    'div',
    { class: 'tachyon_diagnostic-page__right-bar__actions' },
    groups,
  );
}
