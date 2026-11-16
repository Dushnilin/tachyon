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

export function getCheckToastMessage(
  status: UpdateStatus,
  currentVersion?: string,
  latestVersion?: string,
): string {
  if (status === 'outdated' || status === 'outdated_same_release') {
    const cleanCurrent =
      currentVersion &&
      currentVersion !== 'not installed' &&
      currentVersion !== _('Not installed') &&
      currentVersion !== _('Loading...')
        ? currentVersion
        : '';
    if (cleanCurrent && latestVersion && cleanCurrent !== latestVersion) {
      return `${_('Update is available')}: ${cleanCurrent} → ${latestVersion}`;
    }
    if (latestVersion) {
      return `${_('Update is available')}: ${latestVersion}`;
    }
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
  if (button.action !== 'install' && button.action !== 'reinstall') {
    return undefined;
  }

  return updatesChecks[button.component]?.latest_version || undefined;
}
