import { renderCheckIcon24, renderXIcon24 } from '../../../../icons';
import { renderButton } from '../../../../partials';
import { copyToClipboard } from '../../../../helpers/copyToClipboard';
import { TachyonShellMethods } from '../../../methods';
import { Tachyon } from '../../../types';

export interface UpdateProgressModalOptions {
  component: Tachyon.ComponentName;
  action: Tachyon.ComponentAction;
  componentTitle: string;
  currentVersion?: string;
  targetVersion?: string;
  currentSha?: string;
  targetSha?: string;
}

export interface CompleteSuccessOptions {
  autoCloseMs?: number;
  reloadPage?: boolean;
  onInstall?: () => void;
  installText?: string;
}

export interface UpdateProgressModalController {
  updateStep: (stepIndex: number, statusText?: string) => void;
  updateStatus: (statusText: string) => void;
  updateVersions: (opts: {
    currentVersion?: string;
    targetVersion?: string;
    currentSha?: string;
    targetSha?: string;
  }) => void;
  completeSuccess: (message?: string, options?: CompleteSuccessOptions) => void;
  completeError: (errorMessage: string) => void;
  startLogTracking: (jobId: string) => void;
  stopLogTracking: () => void;
  getLogText: () => string;
  close: () => void;
}

function formatSha(sha?: string): string {
  if (!sha) return '';
  const clean = sha.trim();
  return clean.length >= 7 ? clean.slice(0, 7) : clean;
}

function renderVersionBadgeText(opts: {
  currentVersion?: string;
  targetVersion?: string;
  currentSha?: string;
  targetSha?: string;
  action: string;
}): string {
  const cVer = opts.currentVersion || '';
  const tVer = opts.targetVersion || '';
  const cSha = formatSha(opts.currentSha);
  const tSha = formatSha(opts.targetSha);

  if (tVer) {
    if (cVer === tVer) {
      if (cSha && tSha && cSha !== tSha) {
        return `${cVer} (${cSha} → ${tSha})`;
      }
      if (tSha) {
        return `${cVer} (${tSha})`;
      }
      if (cSha) {
        return `${cVer} (${cSha})`;
      }
      return `${cVer} → ${tVer}`;
    }

    const currentPart = cVer ? (cSha ? `${cVer} (${cSha})` : cVer) : '';
    const targetPart = tSha ? `${tVer} (${tSha})` : tVer;

    return currentPart ? `${currentPart} → ${targetPart}` : targetPart;
  }

  if (cVer) {
    return cSha ? `${cSha}` : cVer;
  }

  return opts.action;
}

let activeModalController: UpdateProgressModalController | null = null;
let activeModalJobId: string | null = null;

export function getActiveProgressModalController() {
  return activeModalController;
}

export function setActiveProgressModalJobId(jobId: string | null) {
  activeModalJobId = jobId;
}

export function getActiveProgressModalJobId() {
  return activeModalJobId;
}

export function showUpdateProgressModal(
  options: UpdateProgressModalOptions,
): UpdateProgressModalController {
  if (activeModalController) {
    activeModalController.close();
  }

  const isCheckAction = options.action === 'check_update';

  let modalTitleText = _('Operation in progress...');
  if (isCheckAction) {
    modalTitleText = `${_('Checking for updates...')}: ${options.componentTitle}`;
  } else if (options.action === 'remove') {
    modalTitleText = `${_('Removing')} ${options.componentTitle}...`;
  } else {
    modalTitleText = `${_('Updating')} ${options.componentTitle}...`;
  }

  let elapsedSeconds = 0;
  let timerInterval: ReturnType<typeof setInterval> | null = null;
  let isCompleted = false;
  let currentModalVersions = { ...options };

  const timerBadgeEl = E(
    'div',
    { class: 'tachyon-update-modal__timer-badge' },
    '⏱️ 00:00',
  );

  const titleBadgeEl = E(
    'span',
    { class: 'tachyon-update-modal__version-badge' },
    renderVersionBadgeText(options),
  );

  const headerEl = E('div', { class: 'tachyon-update-modal__header' }, [
    E('div', { class: 'tachyon-update-modal__header-info' }, [
      E(
        'b',
        { class: 'tachyon-update-modal__component-name' },
        options.componentTitle,
      ),
      titleBadgeEl,
    ]),
    timerBadgeEl,
  ]);

  const logPreEl = E('pre', {
    class: 'tachyon-update-modal__log',
  }) as HTMLPreElement;

  const logPanelEl = E(
    'div',
    { class: 'tachyon-update-modal__log-panel' },
    [
      E('div', { class: 'tachyon-update-modal__log-header' }, [
        E('b', {}, _('Operation log')),
        renderButton({
          classNames: ['cbi-button-action', 'tachyon-update-modal__log-copy'],
          text: _('Copy log'),
          onClick: copyLog,
        }),
      ]),
      logPreEl,
    ],
  );

  const actionButtonContainer = E(
    'div',
    { class: 'tachyon-update-modal__actions' },
    [
      renderButton({
        text: _('Operation in progress...'),
        disabled: true,
        loading: true,
        onClick: () => {},
      }),
    ],
  );

  const modalBodyEl = E('div', { class: 'tachyon-update-modal__body' }, [
    headerEl,
    logPanelEl,
    actionButtonContainer,
  ]) as HTMLElement;

  const updateTimerDisplay = () => {
    const mins = Math.floor(elapsedSeconds / 60)
      .toString()
      .padStart(2, '0');
    const secs = (elapsedSeconds % 60).toString().padStart(2, '0');
    timerBadgeEl.textContent = `⏱️ ${mins}:${secs}`;
  };

  timerInterval = setInterval(() => {
    elapsedSeconds += 1;
    updateTimerDisplay();
  }, 1000);

  function cleanupTimers() {
    if (timerInterval) {
      clearInterval(timerInterval);
      timerInterval = null;
    }
  }

  let logTrackingJobId: string | null = null;
  let logTrackingOffset = 0;
  let logFullText = '';
  let logPollTimer: ReturnType<typeof setTimeout> | null = null;
  let logPollStopped = true;

  function appendLogText(text: string) {
    if (!text) {
      return;
    }
    logFullText += text;
    logPreEl.textContent = logFullText;
    logPreEl.scrollTop = logPreEl.scrollHeight;
  }

  async function pollLog() {
    if (logPollStopped || !logTrackingJobId) {
      return;
    }

    const jobId = logTrackingJobId;
    const offset = logTrackingOffset;

    try {
      const response = await TachyonShellMethods.componentActionLog(
        jobId,
        offset,
      );
      if (logPollStopped || logTrackingJobId !== jobId) {
        return;
      }
      if (response.success && response.data) {
        logTrackingOffset = response.data.offset;
        appendLogText(response.data.log);
      }
    } catch (_error) {
      // A transient RPC failure must not stop the polling; the next tick retries.
    } finally {
      if (!logPollStopped && logTrackingJobId === jobId) {
        logPollTimer = setTimeout(pollLog, 1500);
      }
    }
  }

  function stopLogTracking() {
    logPollStopped = true;
    if (logPollTimer) {
      clearTimeout(logPollTimer);
      logPollTimer = null;
    }
    logTrackingJobId = null;
  }

  function finishLogTracking() {
    if (logPollStopped || !logTrackingJobId) {
      stopLogTracking();
      return;
    }

    const jobId = logTrackingJobId;
    const offset = logTrackingOffset;
    logPollStopped = true;
    if (logPollTimer) {
      clearTimeout(logPollTimer);
      logPollTimer = null;
    }

    void TachyonShellMethods.componentActionLog(jobId, offset)
      .then((response) => {
        if (response.success && response.data) {
          logTrackingOffset = response.data.offset;
          appendLogText(response.data.log);
        }
      })
      .catch(() => {})
      .finally(() => {
        logTrackingJobId = null;
      });
  }

  function copyLog() {
    if (!logFullText) {
      return;
    }

    copyToClipboard(logFullText);
  }

  const controller: UpdateProgressModalController = {
    updateStep: (_stepIndex: number, _statusText?: string) => {
      // noop — step UI removed, log is the primary content
    },
    updateStatus: (_statusText: string) => {
      // noop — status merged into log
    },
    updateVersions: (opts: {
      currentVersion?: string;
      targetVersion?: string;
      currentSha?: string;
      targetSha?: string;
    }) => {
      currentModalVersions = {
        ...currentModalVersions,
        ...opts,
      };
      titleBadgeEl.textContent = renderVersionBadgeText(currentModalVersions);
    },
    completeSuccess: (message?: string, opts?: CompleteSuccessOptions) => {
      isCompleted = true;
      cleanupTimers();
      finishLogTracking();

      const successMsg =
        message ||
        (isCheckAction
          ? _('Check completed!')
          : options.action === 'remove'
            ? _('Removal completed successfully!')
            : _('Update completed successfully!'));

      actionButtonContainer.replaceChildren(
        E('div', { class: 'tachyon-update-modal__success-banner' }, [
          renderCheckIcon24(),
          E('span', {}, successMsg),
        ]),
      );

      if (opts?.reloadPage) {
        let secondsLeft = 3;
        const reloadBtnText = () =>
          `${_('Reloading page in')} ${secondsLeft}s...`;

        const closeBtn = renderButton({
          classNames: ['cbi-button-save'],
          text: reloadBtnText(),
          onClick: () => {
            window.location.reload();
          },
        });

        actionButtonContainer.replaceChildren(closeBtn);

        const reloadTimer = setInterval(() => {
          secondsLeft -= 1;
          if (secondsLeft <= 0) {
            clearInterval(reloadTimer);
            window.location.reload();
          } else {
            closeBtn.textContent = reloadBtnText();
          }
        }, 1000);
      } else {
        const actionButtons: HTMLElement[] = [];

        if (opts?.onInstall) {
          const installBtn = renderButton({
            classNames: ['cbi-button-save'],
            text: opts.installText || _('Install'),
            onClick: () => {
              controller.close();
              opts.onInstall!();
            },
          });
          actionButtons.push(installBtn);
        }

        const closeBtn = renderButton({
          classNames: ['cbi-button-apply'],
          text: _('Close'),
          onClick: () => {
            controller.close();
          },
        });
        actionButtons.push(closeBtn);

        actionButtonContainer.replaceChildren(...actionButtons);

        const defaultAutoCloseMs = opts?.onInstall
          ? 0
          : isCheckAction
            ? 1200
            : 1200;
        const autoCloseMs = opts?.autoCloseMs ?? defaultAutoCloseMs;
        if (autoCloseMs > 0) {
          setTimeout(() => {
            if (
              activeModalController === controller ||
              activeModalController === null
            ) {
              controller.close();
            }
          }, autoCloseMs);
        }
      }
    },
    completeError: (errorMessage: string) => {
      isCompleted = true;
      cleanupTimers();
      finishLogTracking();

      actionButtonContainer.replaceChildren(
        E('div', { class: 'tachyon-update-modal__error-banner' }, [
          renderXIcon24(),
          E('span', {}, errorMessage || _('Operation failed')),
        ]),
      );

      const closeBtn = renderButton({
        classNames: ['cbi-button-remove'],
        text: _('Close'),
        onClick: () => {
          controller.close();
        },
      });

      actionButtonContainer.appendChild(closeBtn);
    },
    startLogTracking: (jobId: string) => {
      if (!jobId || logTrackingJobId === jobId) {
        return;
      }

      logTrackingJobId = jobId;
      logTrackingOffset = 0;
      logPollStopped = false;

      if (logPollTimer) {
        clearTimeout(logPollTimer);
        logPollTimer = null;
      }
      void pollLog();
    },
    stopLogTracking: () => {
      stopLogTracking();
    },
    getLogText: () => logFullText,
    close: () => {
      cleanupTimers();
      stopLogTracking();
      if (activeModalController === controller) {
        activeModalController = null;
        activeModalJobId = null;
      }
      ui.hideModal();
    },
  };

  activeModalController = controller;
  ui.showModal(modalTitleText, modalBodyEl);

  return controller;
}
