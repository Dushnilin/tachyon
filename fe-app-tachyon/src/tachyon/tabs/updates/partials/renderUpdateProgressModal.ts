import { showToast } from '../../../../helpers/showToast';
import { renderCheckIcon24, renderXIcon24 } from '../../../../icons';
import { renderButton } from '../../../../partials';
import { Tachyon } from '../../../types';

export interface UpdateProgressModalOptions {
  component: Tachyon.ComponentName;
  action: Tachyon.ComponentAction;
  componentTitle: string;
  currentVersion?: string;
  targetVersion?: string;
}

export interface UpdateProgressModalController {
  updateStep: (stepIndex: number, statusText?: string) => void;
  updateStatus: (statusText: string) => void;
  completeSuccess: (
    message?: string,
    options?: { autoCloseMs?: number; reloadPage?: boolean },
  ) => void;
  completeError: (errorMessage: string) => void;
  close: () => void;
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
  const isRemoveAction = options.action === 'remove';
  const isInstallOrUpdate = !isCheckAction && !isRemoveAction;

  let modalTitleText = _('Operation in progress...');
  if (isCheckAction) {
    modalTitleText = `${_('Checking for updates...')}: ${options.componentTitle}`;
  } else if (isRemoveAction) {
    modalTitleText = `${_('Removing')} ${options.componentTitle}...`;
  } else {
    modalTitleText = `${_('Updating')} ${options.componentTitle}...`;
  }

  const steps = isCheckAction
    ? [_('Connecting to update server...'), _('Comparing version releases...')]
    : [
        _('Initializing operation...'),
        _('Downloading package from repository...'),
        _('Installing package & updating configurations...'),
        _('Applying changes & reloading services...'),
      ];

  let currentStepIndex = 0;
  let elapsedSeconds = 0;
  let timerInterval: ReturnType<typeof setInterval> | null = null;
  let autoAdvanceTimer: ReturnType<typeof setInterval> | null = null;
  let isCompleted = false;

  const timerBadgeEl = E(
    'div',
    { class: 'tachyon-update-modal__timer-badge' },
    '⏱️ 00:00',
  );

  const titleBadgeEl = E(
    'span',
    { class: 'tachyon-update-modal__version-badge' },
    options.targetVersion
      ? `${options.currentVersion || ''} → ${options.targetVersion}`
      : options.currentVersion || options.action,
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

  const progressBarFillEl = E('div', {
    class: 'tachyon-update-modal__progress-fill',
    style: 'width: 15%;',
  });

  const progressBarTrackEl = E(
    'div',
    { class: 'tachyon-update-modal__progress-track' },
    [progressBarFillEl],
  );

  const stepItemEls: HTMLElement[] = steps.map((stepText, index) => {
    const iconEl = E(
      'span',
      { class: 'tachyon-update-modal__step-icon' },
      index === 0 ? '⚡' : '○',
    );
    const labelEl = E(
      'span',
      { class: 'tachyon-update-modal__step-label' },
      stepText,
    );
    return E(
      'div',
      {
        class: [
          'tachyon-update-modal__step-item',
          index === 0 ? 'tachyon-update-modal__step-item--active' : '',
        ]
          .filter(Boolean)
          .join(' '),
      },
      [iconEl, labelEl],
    ) as HTMLElement;
  });

  const stepListEl = E(
    'div',
    { class: 'tachyon-update-modal__step-list' },
    stepItemEls,
  );

  const statusMsgEl = E(
    'div',
    { class: 'tachyon-update-modal__status-msg' },
    steps[0] || _('Please wait, operation is running...'),
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
    progressBarTrackEl,
    stepListEl,
    statusMsgEl,
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

  if (isInstallOrUpdate) {
    autoAdvanceTimer = setInterval(() => {
      if (isCompleted) return;
      if (elapsedSeconds >= 4 && currentStepIndex === 0) {
        setStep(1);
      } else if (elapsedSeconds >= 12 && currentStepIndex === 1) {
        setStep(2);
      } else if (elapsedSeconds >= 25 && currentStepIndex === 2) {
        setStep(3);
      }
    }, 1000);
  } else if (isCheckAction) {
    autoAdvanceTimer = setInterval(() => {
      if (isCompleted) return;
      if (elapsedSeconds >= 1 && currentStepIndex === 0) {
        setStep(1);
      }
    }, 800);
  }

  function setStep(stepIndex: number, customStatus?: string) {
    if (stepIndex < 0 || stepIndex >= steps.length) return;
    currentStepIndex = stepIndex;

    const percent = Math.round(((stepIndex + 1) / (steps.length + 0.5)) * 100);
    progressBarFillEl.style.width = `${Math.min(percent, 92)}%`;

    stepItemEls.forEach((item, idx) => {
      const iconEl = item.querySelector('.tachyon-update-modal__step-icon');
      item.classList.remove(
        'tachyon-update-modal__step-item--active',
        'tachyon-update-modal__step-item--done',
      );

      if (idx < stepIndex) {
        item.classList.add('tachyon-update-modal__step-item--done');
        if (iconEl) iconEl.textContent = '✓';
      } else if (idx === stepIndex) {
        item.classList.add('tachyon-update-modal__step-item--active');
        if (iconEl) iconEl.textContent = '⚡';
      } else {
        if (iconEl) iconEl.textContent = '○';
      }
    });

    if (customStatus) {
      statusMsgEl.textContent = customStatus;
    } else if (steps[stepIndex]) {
      statusMsgEl.textContent = steps[stepIndex];
    }
  }

  function cleanupTimers() {
    if (timerInterval) {
      clearInterval(timerInterval);
      timerInterval = null;
    }
    if (autoAdvanceTimer) {
      clearInterval(autoAdvanceTimer);
      autoAdvanceTimer = null;
    }
  }

  const controller: UpdateProgressModalController = {
    updateStep: (stepIndex: number, statusText?: string) => {
      setStep(stepIndex, statusText);
    },
    updateStatus: (statusText: string) => {
      statusMsgEl.textContent = statusText;
    },
    completeSuccess: (
      message?: string,
      opts?: { autoCloseMs?: number; reloadPage?: boolean },
    ) => {
      isCompleted = true;
      cleanupTimers();

      progressBarFillEl.style.width = '100%';
      progressBarFillEl.classList.add(
        'tachyon-update-modal__progress-fill--success',
      );

      stepItemEls.forEach((item) => {
        item.classList.remove('tachyon-update-modal__step-item--active');
        item.classList.add('tachyon-update-modal__step-item--done');
        const iconEl = item.querySelector('.tachyon-update-modal__step-icon');
        if (iconEl) iconEl.textContent = '✓';
      });

      const successMsg =
        message ||
        (isCheckAction
          ? _('Check completed!')
          : isRemoveAction
            ? _('Removal completed successfully!')
            : _('Update completed successfully!'));

      statusMsgEl.replaceChildren(
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
        const closeBtn = renderButton({
          classNames: ['cbi-button-apply'],
          text: _('Close'),
          onClick: () => {
            controller.close();
          },
        });

        actionButtonContainer.replaceChildren(closeBtn);

        const autoCloseMs = opts?.autoCloseMs ?? (isCheckAction ? 1000 : 2200);
        if (autoCloseMs > 0) {
          setTimeout(() => {
            if (activeModalController === controller) {
              controller.close();
            }
          }, autoCloseMs);
        }
      }
    },
    completeError: (errorMessage: string) => {
      isCompleted = true;
      cleanupTimers();

      progressBarFillEl.style.width = '100%';
      progressBarFillEl.classList.add(
        'tachyon-update-modal__progress-fill--error',
      );

      statusMsgEl.replaceChildren(
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

      actionButtonContainer.replaceChildren(closeBtn);
    },
    close: () => {
      cleanupTimers();
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
