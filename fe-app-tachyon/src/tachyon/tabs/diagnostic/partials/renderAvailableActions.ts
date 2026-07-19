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
} from '../../../../icons';
import { insertIf } from '../../../../helpers';

interface ActionProps {
  loading: boolean;
  visible: boolean;
  disabled: boolean;
  onClick: () => void;
}

interface IRenderAvailableActionsProps {
  restart: ActionProps;
  start: ActionProps;
  stop: ActionProps;
  enable: ActionProps;
  disable: ActionProps;
  globalCheck: ActionProps;
  doctor: ActionProps;
  viewLogs: ActionProps;
  showSingBoxConfig: ActionProps;
  generateBugReport: ActionProps;
}

export function renderAvailableActions({
  restart,
  start,
  stop,
  enable,
  disable,
  globalCheck,
  doctor,
  viewLogs,
  showSingBoxConfig,
  generateBugReport,
}: IRenderAvailableActionsProps) {
  return E('div', { class: 'tachyon_diagnostic-page__right-bar__actions' }, [
    E('b', {}, _('Available actions')),
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
    ...insertIf(globalCheck.visible, [
      renderButton({
        onClick: globalCheck.onClick,
        icon: renderCircleCheckBigIcon24,
        text: _('Get global check'),
        loading: globalCheck.loading,
        disabled: globalCheck.disabled,
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
        text: _('Show sing-box config'),
        loading: showSingBoxConfig.loading,
        disabled: showSingBoxConfig.disabled,
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
  ]);
}
