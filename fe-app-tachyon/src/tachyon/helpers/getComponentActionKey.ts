import type { StoreType } from '../services/store.service';
import type { Tachyon } from '../types';

export type UpdatesActionKey = keyof StoreType['updatesActions'];

const componentActionKeyMap: Record<string, UpdatesActionKey> = {
  'tachyon:check_update': 'tachyonCheck',
  'tachyon:install': 'tachyonInstall',
  'tachyon:install_version': 'tachyonInstall',
  'tachyon:reinstall': 'tachyonReinstall',
  'tachyon:rollback': 'tachyonRollback',
  'sing_box:check_update': 'singBoxCheck',
  'sing_box:install': 'singBoxInstall',
  'sing_box:install_version': 'singBoxInstall',
  'sing_box:rollback': 'singBoxRollback',
  'sing_box:install_extended': 'singBoxInstallExtended',
  'sing_box:install_extended_compressed': 'singBoxInstallExtendedCompressed',
  'sing_box:install_lx': 'singBoxInstallLx',
  'sing_box:install_tiny': 'singBoxInstallTiny',
  'sing_box:install_stable': 'singBoxInstallStable',
  'zapret:check_update': 'zapretCheck',
  'zapret:install': 'zapretInstall',
  'zapret:install_version': 'zapretInstall',
  'zapret:remove': 'zapretRemove',
  'zapret:rollback': 'zapretRollback',
  'zapret2:check_update': 'zapret2Check',
  'zapret2:install': 'zapret2Install',
  'zapret2:install_version': 'zapret2Install',
  'zapret2:remove': 'zapret2Remove',
  'zapret2:rollback': 'zapret2Rollback',
  'byedpi:check_update': 'byedpiCheck',
  'byedpi:install': 'byedpiInstall',
  'byedpi:install_version': 'byedpiInstall',
  'byedpi:remove': 'byedpiRemove',
  'byedpi:rollback': 'byedpiRollback',
  'wdtt:check_update': 'wdttCheck',
  'wdtt:install': 'wdttInstall',
  'wdtt:install_version': 'wdttInstall',
  'wdtt:remove': 'wdttRemove',
  'wdtt:rollback': 'wdttRollback',
  'olcrtc:check_update': 'olcrtcCheck',
  'olcrtc:install': 'olcrtcInstall',
  'olcrtc:install_version': 'olcrtcInstall',
  'olcrtc:remove': 'olcrtcRemove',
  'olcrtc:rollback': 'olcrtcRollback',
  'tailscale:check_update': 'tailscaleCheck',
  'tailscale:install': 'tailscaleInstall',
  'tailscale:install_version': 'tailscaleInstall',
  'tailscale:remove': 'tailscaleRemove',
  'tailscale:rollback': 'tailscaleRollback',
  'direct_bypass:enable': 'directBypassEnable',
  'direct_bypass:disable': 'directBypassDisable',
  'torrserver_direct:enable': 'torrserverDirectEnable',
  'torrserver_direct:disable': 'torrserverDirectDisable',
};

export function getComponentActionKey(
  component: Tachyon.ComponentName,
  action: Tachyon.ComponentAction,
): UpdatesActionKey | undefined {
  return componentActionKeyMap[`${component}:${action}`];
}
