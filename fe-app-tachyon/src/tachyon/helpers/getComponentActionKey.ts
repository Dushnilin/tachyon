import type { StoreType } from '../services/store.service';
import type { Tachyon } from '../types';

export type UpdatesActionKey = keyof StoreType['updatesActions'];

const componentActionKeyMap: Record<string, UpdatesActionKey> = {
  'tachyon:check_update': 'tachyonCheck',
  'tachyon:install': 'tachyonInstall',
  'tachyon:install_version': 'tachyonInstall',
  'tachyon:reinstall': 'tachyonReinstall',
  'tachyon:rollback': 'tachyonRollback',
  'tachyon-core:check_update': 'tachyonCoreCheck',
  'tachyon-core:install': 'tachyonCoreInstall',
  'tachyon-core:install_version': 'tachyonCoreInstall',
  'tachyon-core:reinstall': 'tachyonCoreInstall',
  'tachyon-core:rollback': 'tachyonCoreRollback',
  'direct_bypass:enable': 'directBypassEnable',
  'direct_bypass:disable': 'directBypassDisable',
  'torrserver_direct:check_update': 'torrserverDirectCheck',
  'torrserver_direct:install': 'torrserverDirectInstall',
  'torrserver_direct:install_version': 'torrserverDirectInstall',
  'torrserver_direct:remove': 'torrserverDirectRemove',
  'torrserver_direct:enable': 'torrserverDirectEnable',
  'torrserver_direct:disable': 'torrserverDirectDisable',
};

export function getComponentActionKey(
  component: Tachyon.ComponentName,
  action: Tachyon.ComponentAction,
): UpdatesActionKey | undefined {
  return componentActionKeyMap[`${component}:${action}`];
}
