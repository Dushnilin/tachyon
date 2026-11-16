import {
  renderDownloadIcon24,
  renderRotateCcwIcon24,
  renderSearchIcon24,
} from '../../../icons';
import type { UpdatesActionKey } from '../../helpers/getComponentActionKey';
import type { StoreType } from '../../services/store.service';
import { Tachyon } from '../../types';

export interface ComponentActionButton {
  key: UpdatesActionKey;
  text: string;
  icon: () => SVGSVGElement;
  component: Tachyon.ComponentName;
  action: Tachyon.ComponentAction;
  targetVersion?: string;
  disabled?: boolean;
}

export interface ComponentCard {
  component: Tachyon.ComponentName;
  column: 0 | 1 | 2;
  title: string;
  version: string;
  latestVersion?: string;
  releaseUrl?: string;
  repoUrl?: string;
  actions: ComponentActionButton[];
  badgeNode?: Node | null;
  supportsVersions?: boolean;
  copyValue?: string;
}

export function getComponentCardTitle(
  component: Tachyon.ComponentName,
): string {
  switch (component) {
    case 'tachyon':
      return 'Tachyon';
    case 'tachyon-core':
      return 'Tachyon Core';
    case 'torrserver_direct':
      return _('TorrServer Direct');
    default:
      return String(component);
  }
}

export function getComponentCurrentVersion(
  component: Tachyon.ComponentName,
  sys: StoreType['diagnosticsSystemInfo'],
): string | undefined {
  switch (component) {
    case 'tachyon':
      return sys.tachyon_version;
    case 'tachyon-core':
      return sys.tachyon_core_version;
    case 'torrserver_direct':
      return sys.torrserver_version;
    default:
      return undefined;
  }
}

export function getComponentBackupVersion(
  component: Tachyon.ComponentName,
  sys: StoreType['diagnosticsSystemInfo'],
): string {
  switch (component) {
    case 'tachyon-core':
      return sys.tachyon_core_backup_version || '';
    default:
      return '';
  }
}

export function getComponentInstallKey(
  component: Tachyon.ComponentName,
): UpdatesActionKey {
  switch (component) {
    case 'tachyon':
      return 'tachyonInstall';
    case 'tachyon-core':
      return 'tachyonCoreInstall';
    case 'torrserver_direct':
      return 'torrserverDirectInstall';
    default:
      return 'tachyonInstall';
  }
}

export function getCheckAction(
  component: Tachyon.ComponentName,
  key: UpdatesActionKey,
): ComponentActionButton {
  return {
    key,
    text: _('Check update'),
    icon: renderSearchIcon24,
    component,
    action: 'check_update',
  };
}

export function getInstallAction(
  component: Tachyon.ComponentName,
  key: UpdatesActionKey,
  installed: boolean,
  currentVersion?: string,
  latestVersion?: string,
): ComponentActionButton {
  let text = installed ? _('Update') : _('Install');
  if (installed && latestVersion) {
    const cleanCurrent =
      currentVersion &&
      currentVersion !== 'not installed' &&
      currentVersion !== _('Not installed') &&
      currentVersion !== _('Loading...')
        ? currentVersion
        : '';
    if (cleanCurrent && cleanCurrent !== latestVersion) {
      text = `${_('Update')} (${cleanCurrent} → ${latestVersion})`;
    } else {
      text = `${_('Update')} (${latestVersion})`;
    }
  }
  return {
    key,
    text,
    icon: installed ? renderRotateCcwIcon24 : renderDownloadIcon24,
    component,
    action: 'install',
  };
}

export function getRollbackAction(
  component: Tachyon.ComponentName,
  key: UpdatesActionKey,
  backupVersion: string,
): ComponentActionButton {
  return {
    key,
    text: backupVersion ? `${_('Rollback')} (${backupVersion})` : _('Rollback'),
    icon: renderRotateCcwIcon24,
    component,
    action: 'rollback',
  };
}

export function getInstalledUpdateActions({
  component,
  checkKey,
  installKey,
  installed = true,
  hasUpdate = false,
}: {
  component: Tachyon.ComponentName;
  checkKey: UpdatesActionKey;
  installKey: UpdatesActionKey;
  installed?: boolean;
  hasUpdate?: boolean;
}): ComponentActionButton[] {
  if (!installed) {
    return [];
  }

  const actions = [getCheckAction(component, checkKey)];
  if (hasUpdate) {
    actions.push(getInstallAction(component, installKey, true));
  }
  return actions;
}

export const COMPONENT_REPO_URLS: Record<Tachyon.ComponentName, string> = {
  tachyon: 'https://github.com/Dushnilin/tachyon',
  'tachyon-core': 'https://github.com/Dushnilin/tachyon-core',
  direct_bypass: '',
  torrserver_direct: 'https://github.com/YouROK/TorrServer',
};
