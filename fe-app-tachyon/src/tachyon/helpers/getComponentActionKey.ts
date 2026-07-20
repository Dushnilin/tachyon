import type { StoreType } from '../services/store.service';
import type { Tachyon } from '../types';

export type UpdatesActionKey = keyof StoreType['updatesActions'];

const componentActionKeyMap: Record<string, UpdatesActionKey> = {
  'tachyon:check_update': 'tachyonCheck',
  'tachyon:install': 'tachyonInstall',
  'sing_box:check_update': 'singBoxCheck',
  'sing_box:install': 'singBoxInstall',
  'sing_box:install_extended': 'singBoxInstallExtended',
  'sing_box:install_extended_compressed': 'singBoxInstallExtendedCompressed',
  'sing_box:install_lx': 'singBoxInstallLx',
  'sing_box:install_tiny': 'singBoxInstallTiny',
  'sing_box:install_stable': 'singBoxInstallStable',
  'zapret:check_update': 'zapretCheck',
  'zapret:install': 'zapretInstall',
  'zapret:remove': 'zapretRemove',
  'zapret2:check_update': 'zapret2Check',
  'zapret2:install': 'zapret2Install',
  'zapret2:remove': 'zapret2Remove',
  'byedpi:check_update': 'byedpiCheck',
  'byedpi:install': 'byedpiInstall',
  'byedpi:remove': 'byedpiRemove',
};

export function getComponentActionKey(
  component: Tachyon.ComponentName,
  action: Tachyon.ComponentAction,
): UpdatesActionKey | undefined {
  return componentActionKeyMap[`${component}:${action}`];
}
