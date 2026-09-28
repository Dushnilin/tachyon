import { describe, expect, it, vi } from 'vitest';
import {
  getCheckToastMessage,
  getErrorMessage,
  getExpectedLatestVersionForAction,
  isComponentActionAlreadyRunningError,
  notifyActionProvidersAvailabilityChanged,
} from '../notifications';
import { TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT } from '../../../../constants';

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
          component: 'sing_box',
          action: 'install',
          targetVersion: '1.11.0',
        },
        {},
      ),
    ).toBe('1.11.0');

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

    // Other components without targetVersion return undefined
    expect(
      getExpectedLatestVersionForAction(
        {
          component: 'zapret',
          action: 'install',
        },
        {
          zapret: { latest_version: '69.0' },
        },
      ),
    ).toBeUndefined();
  });

  it('dispatches provider availability change event on window', () => {
    const dispatchFn = vi.fn();
    class MockCustomEvent {
      type: string;
      detail: unknown;
      constructor(type: string, init?: { detail?: unknown }) {
        this.type = type;
        this.detail = init?.detail;
      }
    }

    vi.stubGlobal('window', { dispatchEvent: dispatchFn });
    vi.stubGlobal('CustomEvent', MockCustomEvent);

    try {
      notifyActionProvidersAvailabilityChanged({
        zapret_installed: 1,
        zapret2_installed: 0,
        byedpi_installed: 1,
        wdtt_installed: 0,
        olcrtc_installed: 0,
      });

      expect(dispatchFn).toHaveBeenCalledTimes(1);
      const event = dispatchFn.mock.calls[0][0] as MockCustomEvent;
      expect(event.type).toBe(TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT);
      expect(event.detail).toEqual({
        zapretInstalled: true,
        zapret2Installed: false,
        byedpiInstalled: true,
        wdttInstalled: false,
        olcrtcInstalled: false,
      });
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
