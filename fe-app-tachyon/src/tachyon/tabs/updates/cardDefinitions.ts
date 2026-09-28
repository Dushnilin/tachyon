import {
  renderDownloadIcon24,
  renderRotateCcwIcon24,
  renderSearchIcon24,
  renderXIcon24,
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
    case 'sing_box':
      return 'Sing-box';
    case 'zapret':
      return 'Zapret';
    case 'zapret2':
      return 'Zapret2';
    case 'byedpi':
      return 'ByeDPI';
    case 'wdtt':
      return 'WDTT';
    case 'olcrtc':
      return 'OlcRTC';
    case 'fptn':
      return 'FPTN';
    case 'tailscale':
      return 'Tailscale';
    case 'steer':
      return 'Steer';
    case 'steer-extended':
      return 'Steer extended';
    case 'engine':
      return _('Routing Engine');
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
    case 'sing_box':
      return sys.sing_box_version;
    case 'zapret':
      return sys.zapret_version;
    case 'zapret2':
      return sys.zapret2_version;
    case 'byedpi':
      return sys.byedpi_version;
    case 'wdtt':
      return sys.wdtt_version;
    case 'olcrtc':
      return sys.olcrtc_version;
    case 'fptn':
      return sys.fptn_version;
    case 'tailscale':
      return sys.tailscale_version;
    case 'steer':
    case 'steer-extended':
      return sys.steer_version;
    default:
      return undefined;
  }
}

export function getComponentBackupVersion(
  component: Tachyon.ComponentName,
  sys: StoreType['diagnosticsSystemInfo'],
): string {
  switch (component) {
    case 'sing_box':
      return sys.sing_box_backup_version || '';
    case 'zapret':
      return sys.zapret_backup_version || '';
    case 'zapret2':
      return sys.zapret2_backup_version || '';
    case 'byedpi':
      return sys.byedpi_backup_version || '';
    case 'wdtt':
      return sys.wdtt_backup_version || '';
    case 'olcrtc':
      return sys.olcrtc_backup_version || '';
    case 'fptn':
      return sys.fptn_backup_version || '';
    case 'tailscale':
      return sys.tailscale_backup_version || '';
    case 'steer':
    case 'steer-extended':
      return sys.steer_backup_version || '';
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
    case 'sing_box':
      return 'singBoxInstall';
    case 'zapret':
      return 'zapretInstall';
    case 'zapret2':
      return 'zapret2Install';
    case 'byedpi':
      return 'byedpiInstall';
    case 'wdtt':
      return 'wdttInstall';
    case 'olcrtc':
      return 'olcrtcInstall';
    case 'tailscale':
      return 'tailscaleInstall';
    case 'steer':
    case 'steer-extended':
      return 'steerInstall';
    case 'engine':
      return 'engineSwitch';
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
): ComponentActionButton {
  return {
    key,
    text: installed ? _('Update') : _('Install'),
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

export function getOptionalComponentActions({
  component,
  installed,
  checkKey,
  installKey,
  removeKey,
  rollbackKey,
  hasUpdate = false,
  backupVersion = '',
}: {
  component:
    | 'zapret'
    | 'zapret2'
    | 'byedpi'
    | 'wdtt'
    | 'olcrtc'
    | 'fptn'
    | 'tailscale';
  installed: boolean;
  checkKey: UpdatesActionKey;
  installKey: UpdatesActionKey;
  removeKey: UpdatesActionKey;
  rollbackKey: UpdatesActionKey;
  hasUpdate?: boolean;
  backupVersion?: string;
}): ComponentActionButton[] {
  if (!installed) {
    return [getInstallAction(component, installKey, false)];
  }

  const actions = [
    ...getInstalledUpdateActions({
      component,
      checkKey,
      installKey,
      hasUpdate,
    }),
    {
      key: removeKey,
      text: _('Remove'),
      icon: renderXIcon24,
      component,
      action: 'remove' as const,
    },
  ];

  if (backupVersion) {
    actions.push(getRollbackAction(component, rollbackKey, backupVersion));
  }

  return actions;
}

export const COMPONENT_REPO_URLS: Record<Tachyon.ComponentName, string> = {
  tachyon: 'https://github.com/Dushnilin/tachyon',
  sing_box: 'https://github.com/SagerNet/sing-box',
  zapret: 'https://github.com/remittor/zapret-openwrt',
  zapret2: 'https://github.com/Dushnilin/zapret2-openwrt',
  byedpi: 'https://github.com/DPITrickster/ByeDPI-OpenWrt',
  wdtt: 'https://github.com/Dushnilin/qwdtt-openwrt',
  olcrtc: 'https://github.com/Dushnilin/openwrt-olcrtc',
  fptn: 'https://github.com/Dushnilin/fptn',
  tailscale: 'https://openwrt.org/packages/pkgdata/tailscale',
  steer: 'https://github.com/xyzmean/steer',
  'steer-extended': 'https://github.com/xyzmean/steer',
  direct_bypass: '',
  torrserver_direct: '',
  engine: '',
};
