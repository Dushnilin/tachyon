import { TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT } from '../../../constants';
import type { StoreType } from '../../services/store.service';
import { Tachyon } from '../../types';

export type UpdateStatus =
  StoreType['updatesChecks'][Tachyon.ComponentName]['status'];

export interface ComponentActionButtonLike {
  component: Tachyon.ComponentName;
  action: Tachyon.ComponentAction;
  targetVersion?: string;
}

export function getErrorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

export function isComponentActionAlreadyRunningError(
  message: string | undefined,
): boolean {
  return Boolean(
    message && message.includes('Another component action is already running'),
  );
}

export function getCheckToastMessage(status: UpdateStatus): string {
  if (status === 'outdated' || status === 'outdated_same_release') {
    return _('Update is available');
  }

  if (status === 'dev') {
    return _('Installed version is newer than release');
  }

  return _('Latest version is installed');
}

export function getExpectedLatestVersionForAction(
  button: ComponentActionButtonLike,
  updatesChecks: Partial<
    Record<Tachyon.ComponentName, { latest_version?: string }>
  >,
): string | undefined {
  if (button.targetVersion) {
    return button.targetVersion;
  }
  if (
    button.component !== 'tachyon' ||
    (button.action !== 'install' && button.action !== 'reinstall')
  ) {
    return undefined;
  }

  return updatesChecks[button.component]?.latest_version || undefined;
}

export function notifyActionProvidersAvailabilityChanged(
  systemInfo: Pick<
    StoreType['diagnosticsSystemInfo'],
    | 'zapret_installed'
    | 'zapret2_installed'
    | 'byedpi_installed'
    | 'wdtt_installed'
    | 'olcrtc_installed'
  >,
): void {
  if (typeof window === 'undefined' || typeof CustomEvent === 'undefined') {
    return;
  }

  window.dispatchEvent(
    new CustomEvent(TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
      detail: {
        zapretInstalled: Boolean(systemInfo.zapret_installed),
        zapret2Installed: Boolean(systemInfo.zapret2_installed),
        byedpiInstalled: Boolean(systemInfo.byedpi_installed),
        wdttInstalled: Boolean(systemInfo.wdtt_installed),
        olcrtcInstalled: Boolean(systemInfo.olcrtc_installed),
      },
    }),
  );
}
