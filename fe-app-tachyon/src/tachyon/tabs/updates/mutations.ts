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

  return {
    nextSystemInfo,
  };
}
