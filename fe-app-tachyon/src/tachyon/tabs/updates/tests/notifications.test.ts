import { describe, expect, it } from 'vitest';
import {
  getCheckToastMessage,
  getErrorMessage,
  getExpectedLatestVersionForAction,
  isComponentActionAlreadyRunningError,
} from '../notifications';

describe('updates notifications helpers', () => {
  it('formats error message with fallback', () => {
    expect(getErrorMessage(new Error('disk full'), 'default error')).toBe(
      'disk full',
    );
    expect(getErrorMessage('string error', 'default error')).toBe(
      'default error',
    );
    expect(getErrorMessage(null, 'default error')).toBe('default error');
  });

  it('detects when action is already running', () => {
    expect(
      isComponentActionAlreadyRunningError(
        'Failed: Another component action is already running',
      ),
    ).toBe(true);
    expect(
      isComponentActionAlreadyRunningError('Package installation failed'),
    ).toBe(false);
    expect(isComponentActionAlreadyRunningError(undefined)).toBe(false);
  });

  it('returns appropriate toast message for update check status', () => {
    expect(getCheckToastMessage('outdated')).toBe('Update is available');
    expect(getCheckToastMessage('outdated_same_release')).toBe(
      'Update is available',
    );
    expect(getCheckToastMessage('dev')).toBe(
      'Installed version is newer than release',
    );
    expect(getCheckToastMessage('latest')).toBe('Latest version is installed');
    expect(getCheckToastMessage(null)).toBe('Latest version is installed');
  });

  it('determines expected latest version for actions', () => {
    // Explicit targetVersion wins
    expect(
      getExpectedLatestVersionForAction(
        {
          component: 'tachyon-core',
          action: 'install',
          targetVersion: '0.2.4',
        },
        {},
      ),
    ).toBe('0.2.4');

    // Tachyon install without targetVersion pulls from updatesChecks
    expect(
      getExpectedLatestVersionForAction(
        {
          component: 'tachyon',
          action: 'install',
        },
        {
          tachyon: { latest_version: '2.5.0' },
        },
      ),
    ).toBe('2.5.0');

    // Other components without targetVersion also pull from updatesChecks on install
    expect(
      getExpectedLatestVersionForAction(
        {
          component: 'tachyon-core',
          action: 'install',
        },
        {
          'tachyon-core': { latest_version: '0.2.5' },
        },
      ),
    ).toBe('0.2.5');

    // Non-install actions without targetVersion return undefined
    expect(
      getExpectedLatestVersionForAction(
        {
          component: 'tachyon-core',
          action: 'check_update',
        },
        {
          'tachyon-core': { latest_version: '0.2.5' },
        },
      ),
    ).toBeUndefined();
  });
});
