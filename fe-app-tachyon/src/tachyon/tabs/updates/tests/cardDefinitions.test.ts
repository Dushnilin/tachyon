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
  getOptionalComponentActions,
  getRollbackAction,
} from '../cardDefinitions';
import type { StoreType } from '../../../services/store.service';

const mockSystemInfo: StoreType['diagnosticsSystemInfo'] = {
  loading: false,
  loaded: true,
  tachyon_version: '2.5.0',
  sing_box_version: '1.11.0',
  sing_box_backup_version: '1.10.5',
  sing_box_extended: 1,
  sing_box_tiny: 0,
  sing_box_compressed: 0,
  sing_box_lx: 0,
  sing_box_tailscale: 1,
  sing_box_cert_pin: 1,
  zapret_installed: 1,
  zapret_version: '68.0',
  zapret_backup_version: '67.0',
  zapret2_installed: 0,
  zapret2_version: 'not installed',
  byedpi_installed: 1,
  byedpi_version: '0.14.0',
  wdtt_installed: 0,
  wdtt_version: 'not installed',
  olcrtc_installed: 0,
  olcrtc_version: 'not installed',
  fptn_installed: 0,
  fptn_version: 'not installed',
  tailscale_version: 'not installed',
  steer_installed: 1,
  steer_version: '1.5.7',
  steer_extended: 1,
  direct_bypass_enabled: 0,
  torrserver_direct_enabled: 0,
  torrserver_direct_active: 0,
  providerInfoLoaded: true,
} as unknown as StoreType['diagnosticsSystemInfo'];

describe('updates cardDefinitions helpers', () => {
  it('resolves component card titles correctly', () => {
    expect(getComponentCardTitle('tachyon')).toBe('Tachyon');
    expect(getComponentCardTitle('sing_box')).toBe('Sing-box');
    expect(getComponentCardTitle('zapret2')).toBe('Zapret2');
    expect(getComponentCardTitle('engine')).toBe('Routing Engine');
  });

  it('reads current versions from system info', () => {
    expect(getComponentCurrentVersion('tachyon', mockSystemInfo)).toBe('2.5.0');
    expect(getComponentCurrentVersion('sing_box', mockSystemInfo)).toBe(
      '1.11.0',
    );
    expect(getComponentCurrentVersion('zapret', mockSystemInfo)).toBe('68.0');
    expect(getComponentCurrentVersion('steer', mockSystemInfo)).toBe('1.5.7');
    expect(getComponentCurrentVersion('wdtt', mockSystemInfo)).toBe(
      'not installed',
    );
  });

  it('reads backup versions from system info', () => {
    expect(getComponentBackupVersion('sing_box', mockSystemInfo)).toBe(
      '1.10.5',
    );
    expect(getComponentBackupVersion('zapret', mockSystemInfo)).toBe('67.0');
    expect(getComponentBackupVersion('wdtt', mockSystemInfo)).toBe('');
  });

  it('maps install keys for components', () => {
    expect(getComponentInstallKey('tachyon')).toBe('tachyonInstall');
    expect(getComponentInstallKey('sing_box')).toBe('singBoxInstall');
    expect(getComponentInstallKey('zapret2')).toBe('zapret2Install');
    expect(getComponentInstallKey('steer')).toBe('steerInstall');
    expect(getComponentInstallKey('engine')).toBe('engineSwitch');
  });

  it('creates check and install actions', () => {
    const check = getCheckAction('sing_box', 'singBoxCheck');
    expect(check.action).toBe('check_update');
    expect(check.key).toBe('singBoxCheck');

    const installNew = getInstallAction('zapret2', 'zapret2Install', false);
    expect(installNew.text).toBe('Install');
    expect(installNew.action).toBe('install');

    const installExisting = getInstallAction('zapret2', 'zapret2Install', true);
    expect(installExisting.text).toBe('Update');
  });

  it('creates rollback action with or without backup version label', () => {
    const withBackup = getRollbackAction(
      'sing_box',
      'singBoxRollback',
      '1.10.5',
    );
    expect(withBackup.text).toBe('Rollback (1.10.5)');

    const withoutBackup = getRollbackAction('sing_box', 'singBoxRollback', '');
    expect(withoutBackup.text).toBe('Rollback');
  });

  it('generates installed update action sets', () => {
    const withoutUpdate = getInstalledUpdateActions({
      component: 'sing_box',
      checkKey: 'singBoxCheck',
      installKey: 'singBoxInstall',
      hasUpdate: false,
    });
    expect(withoutUpdate).toHaveLength(1);
    expect(withoutUpdate[0].action).toBe('check_update');

    const withUpdate = getInstalledUpdateActions({
      component: 'sing_box',
      checkKey: 'singBoxCheck',
      installKey: 'singBoxInstall',
      hasUpdate: true,
    });
    expect(withUpdate).toHaveLength(2);
    expect(withUpdate.map((a) => a.action)).toEqual([
      'check_update',
      'install',
    ]);
  });

  it('generates optional component action sets', () => {
    // Uninstalled component: only Install action
    const uninstalledActions = getOptionalComponentActions({
      component: 'zapret2',
      installed: false,
      checkKey: 'zapret2Check',
      installKey: 'zapret2Install',
      removeKey: 'zapret2Remove',
      rollbackKey: 'zapret2Rollback',
    });
    expect(uninstalledActions).toHaveLength(1);
    expect(uninstalledActions[0].action).toBe('install');

    // Installed component without update, with backup: check, remove, rollback
    const installedActions = getOptionalComponentActions({
      component: 'zapret',
      installed: true,
      checkKey: 'zapretCheck',
      installKey: 'zapretInstall',
      removeKey: 'zapretRemove',
      rollbackKey: 'zapretRollback',
      hasUpdate: false,
      backupVersion: '67.0',
    });
    expect(installedActions).toHaveLength(3);
    expect(installedActions.map((a) => a.action)).toEqual([
      'check_update',
      'remove',
      'rollback',
    ]);
  });

  it('provides known GitHub / repo URLs', () => {
    expect(COMPONENT_REPO_URLS.tachyon).toContain('tachyon');
    expect(COMPONENT_REPO_URLS.sing_box).toContain('sing-box');
    expect(COMPONENT_REPO_URLS.steer).toContain('steer');
  });
});
