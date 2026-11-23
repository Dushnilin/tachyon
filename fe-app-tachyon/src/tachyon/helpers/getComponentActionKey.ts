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
};

export function getComponentActionKey(
  component: Tachyon.ComponentName,
  action: Tachyon.ComponentAction,
): UpdatesActionKey | undefined {
  return componentActionKeyMap[`${component}:${action}`];
}
