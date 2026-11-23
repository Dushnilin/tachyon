import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../services/tab.service', () => ({
  TabService: {
    getInstance: () => ({ isActive: () => true }),
  },
}));
import {
  COMPONENT_REPO_URLS,
  getCheckAction,
  getComponentBackupVersion,
  getComponentCardTitle,
  getComponentCurrentVersion,
  getComponentInstallKey,
  getInstalledUpdateActions,
  getInstallAction,
  getRollbackAction,
} from '../cardDefinitions';
import type { StoreType } from '../../../services/store.service';

const mockSystemInfo: StoreType['diagnosticsSystemInfo'] = {
  loading: false,
  loaded: true,
  tachyon_version: '2.5.0',
  tachyon_backup_version: '2.4.0',
  tachyon_core_version: '0.2.4',
  tachyon_core_backup_version: '0.2.3',
  tachyon_core_tailscale: 1,
  tachyon_core_cert_pin: 1,
  providerInfoLoaded: true,
} as unknown as StoreType['diagnosticsSystemInfo'];

describe('updates cardDefinitions helpers', () => {
  it('resolves component card titles correctly', () => {
    expect(getComponentCardTitle('tachyon')).toBe('Tachyon');
    expect(getComponentCardTitle('tachyon-core')).toBe('Tachyon Core');
  });

  it('reads current versions from system info', () => {
    expect(getComponentCurrentVersion('tachyon', mockSystemInfo)).toBe('2.5.0');
    expect(getComponentCurrentVersion('tachyon-core', mockSystemInfo)).toBe(
      '0.2.4',
    );
  });

  it('reads backup versions from system info', () => {
    expect(getComponentBackupVersion('tachyon-core', mockSystemInfo)).toBe(
      '0.2.3',
    );
    expect(getComponentBackupVersion('tachyon', mockSystemInfo)).toBe('2.4.0');
  });

  it('maps install keys for components', () => {
    expect(getComponentInstallKey('tachyon')).toBe('tachyonInstall');
    expect(getComponentInstallKey('tachyon-core')).toBe('tachyonCoreInstall');
  });

  it('creates check and install actions', () => {
    const check = getCheckAction('tachyon-core', 'tachyonCoreCheck');
    expect(check.action).toBe('check_update');
    expect(check.key).toBe('tachyonCoreCheck');

    const installNew = getInstallAction(
      'tachyon-core',
      'tachyonCoreInstall',
      false,
    );
    expect(installNew.text).toBe('Install');
    expect(installNew.action).toBe('install');

    const installExisting = getInstallAction(
      'tachyon-core',
      'tachyonCoreInstall',
      true,
    );
    expect(installExisting.text).toBe('Update');

    const installWithVersions = getInstallAction(
      'tachyon',
      'tachyonInstall',
      true,
      '1.6.2',
      '1.7.0',
    );
    expect(installWithVersions.text).toBe('Update (1.6.2 → 1.7.0)');
  });

  it('creates rollback action with or without backup version label', () => {
    const withBackup = getRollbackAction(
      'tachyon-core',
      'tachyonCoreRollback',
      '0.2.3',
    );
    expect(withBackup.text).toBe('Rollback (0.2.3)');

    const withoutBackup = getRollbackAction(
      'tachyon-core',
      'tachyonCoreRollback',
      '',
    );
    expect(withoutBackup.text).toBe('Rollback');
  });

  it('generates installed update action sets', () => {
    const withoutUpdate = getInstalledUpdateActions({
      component: 'tachyon-core',
      checkKey: 'tachyonCoreCheck',
      installKey: 'tachyonCoreInstall',
      hasUpdate: false,
    });
    expect(withoutUpdate).toHaveLength(1);
    expect(withoutUpdate[0].action).toBe('check_update');

    const withUpdate = getInstalledUpdateActions({
      component: 'tachyon-core',
      checkKey: 'tachyonCoreCheck',
      installKey: 'tachyonCoreInstall',
      hasUpdate: true,
    });
    expect(withUpdate).toHaveLength(2);
    expect(withUpdate.map((a) => a.action)).toEqual([
      'check_update',
      'install',
    ]);
  });

  it('provides known GitHub / repo URLs', () => {
    expect(COMPONENT_REPO_URLS.tachyon).toContain('tachyon');
    expect(COMPONENT_REPO_URLS['tachyon-core']).toContain('tachyon-core');
  });
});
