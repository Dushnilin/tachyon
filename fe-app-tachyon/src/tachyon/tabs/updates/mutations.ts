import type { StoreType } from '../../services/store.service';
import { Tachyon } from '../../types';

export interface PatchSystemInfoResult {
  nextSystemInfo: StoreType['diagnosticsSystemInfo'];
}

export type ComponentMutationInput = Pick<
  Tachyon.ComponentActionResult,
  'component' | 'action'
> &
  Partial<Tachyon.ComponentActionResult>;

export function computeSystemInfoMutation(
  currentSystemInfo: StoreType['diagnosticsSystemInfo'],
  result: ComponentMutationInput,
): PatchSystemInfoResult {
  const nextSystemInfo = { ...currentSystemInfo, loading: false, loaded: true };
  const version =
    result.current_version || result.latest_version || _('unknown');

  if (
    result.component === 'tachyon' &&
    (result.action === 'install' || result.action === 'reinstall')
  ) {
    nextSystemInfo.tachyon_version = version;
  }

  if (result.component === 'tachyon-core') {
    nextSystemInfo.tachyon_core_version = version;
    nextSystemInfo.tachyon_core_fptn = 1;
    nextSystemInfo.tachyon_core_tailscale = 1;
    nextSystemInfo.tachyon_core_cert_pin = 1;
  }

  if (result.component === 'direct_bypass') {
    nextSystemInfo.direct_bypass_enabled = result.action === 'enable' ? 1 : 0;
  }
  if (result.component === 'torrserver_direct') {
    if (result.action === 'remove') {
      nextSystemInfo.torrserver_installed = 0;
      nextSystemInfo.torrserver_version = 'not installed';
      nextSystemInfo.torrserver_running = 0;
      nextSystemInfo.torrserver_direct_available = 0;
      nextSystemInfo.torrserver_direct_enabled = 0;
      nextSystemInfo.torrserver_direct_active = 0;
    } else if (
      result.action === 'install' ||
      result.action === 'install_version'
    ) {
      nextSystemInfo.torrserver_installed = 1;
      nextSystemInfo.torrserver_version = version;
      nextSystemInfo.torrserver_running = 1;
      nextSystemInfo.torrserver_direct_available = 1;
      nextSystemInfo.torrserver_direct_enabled = 1;
      nextSystemInfo.torrserver_direct_active = 1;
    } else {
      nextSystemInfo.torrserver_direct_enabled =
        result.action === 'enable' ? 1 : 0;
      nextSystemInfo.torrserver_direct_active =
        result.action === 'enable' ? 1 : 0;
    }
  }

  return {
    nextSystemInfo,
  };
}
