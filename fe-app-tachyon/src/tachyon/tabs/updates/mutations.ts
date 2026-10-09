import { normalizeSingBoxVariantFields } from '../../helpers/singBoxVariant';
import type { StoreType } from '../../services/store.service';
import { Tachyon } from '../../types';

export interface PatchSystemInfoResult {
  nextSystemInfo: StoreType['diagnosticsSystemInfo'];
  notifyActionProviders: boolean;
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

  if (result.component === 'sing_box') {
    nextSystemInfo.sing_box_version = version;

    // Any non-tachyon-core install replaces the binary, so a tachyon-core
    // flag left from the previous state would mislabel the new one.
    if (
      result.action === 'install' ||
      result.action === 'install_version' ||
      result.action === 'reinstall' ||
      result.action === 'install_stable' ||
      result.action === 'install_tiny' ||
      result.action === 'install_extended' ||
      result.action === 'install_extended_compressed' ||
      result.action === 'install_lx'
    ) {
      nextSystemInfo.sing_box_tachyon_core = 0;
      nextSystemInfo.sing_box_fptn = 0;
    }

    if (result.action === 'install_tachyon_core') {
      nextSystemInfo.sing_box_tachyon_core = 1;
      nextSystemInfo.sing_box_fptn = 1;
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_lx = 0;
      nextSystemInfo.sing_box_tailscale = 1;
      nextSystemInfo.sing_box_cert_pin = 1;
    }

    if (result.action === 'install_extended') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_lx = 0;
      nextSystemInfo.sing_box_tailscale = 1;
      nextSystemInfo.sing_box_cert_pin = 1;
    }

    if (result.action === 'install_extended_compressed') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 1;
      nextSystemInfo.sing_box_lx = 0;
      nextSystemInfo.sing_box_tailscale = 1;
      nextSystemInfo.sing_box_cert_pin = 1;
    }

    if (result.action === 'install_lx') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_lx = 1;
      nextSystemInfo.sing_box_tailscale = 1;
      nextSystemInfo.sing_box_cert_pin = 1;
    }

    if (result.action === 'install_stable') {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_lx = 0;
      nextSystemInfo.sing_box_tailscale = 1;
      nextSystemInfo.sing_box_cert_pin = 0;
    }

    if (result.action === 'install_tiny') {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 1;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_lx = 0;
      nextSystemInfo.sing_box_tailscale = 0;
      nextSystemInfo.sing_box_cert_pin = 0;
    }
  }

  if (result.component === 'zapret') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret_installed = 0;
      nextSystemInfo.zapret_version = 'not installed';
    } else {
      nextSystemInfo.zapret_installed = 1;
      nextSystemInfo.zapret_version = version;
    }
  }

  if (result.component === 'zapret2') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret2_installed = 0;
      nextSystemInfo.zapret2_version = 'not installed';
    } else {
      nextSystemInfo.zapret2_installed = 1;
      nextSystemInfo.zapret2_version = version;
    }
  }

  if (result.component === 'byedpi') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.byedpi_installed = 0;
      nextSystemInfo.byedpi_version = 'not installed';
    } else {
      nextSystemInfo.byedpi_installed = 1;
      nextSystemInfo.byedpi_version = version;
    }
  }

  if (result.component === 'wdtt') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.wdtt_installed = 0;
      nextSystemInfo.wdtt_version = 'not installed';
    } else {
      nextSystemInfo.wdtt_installed = 1;
      nextSystemInfo.wdtt_version = version;
    }
  }

  if (result.component === 'olcrtc') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.olcrtc_installed = 0;
      nextSystemInfo.olcrtc_version = 'not installed';
    } else {
      nextSystemInfo.olcrtc_installed = 1;
      nextSystemInfo.olcrtc_version = version;
    }
  }

  if (result.component === 'fptn') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.fptn_installed = 0;
      nextSystemInfo.fptn_version = 'not installed';
    } else if (result.action === 'set_native_mode') {
      nextSystemInfo.fptn_mode = 'native';
    } else if (result.action === 'set_component_mode') {
      nextSystemInfo.fptn_mode = 'component';
    } else {
      nextSystemInfo.fptn_installed = 1;
      nextSystemInfo.fptn_version = version;
    }
  }

  if (result.component === 'steer' || result.component === 'steer-extended') {
    if (result.action === 'remove') {
      nextSystemInfo.steer_installed = 0;
      nextSystemInfo.steer_version = 'not installed';
      nextSystemInfo.steer_extended = 0;
    } else {
      nextSystemInfo.steer_installed = 1;
      nextSystemInfo.steer_version = version;
      nextSystemInfo.steer_extended =
        result.component === 'steer-extended' ? 1 : 0;
    }
  }

  if (result.component === 'direct_bypass') {
    nextSystemInfo.direct_bypass_enabled = result.action === 'enable' ? 1 : 0;
  }
  if (result.component === 'torrserver_direct') {
    nextSystemInfo.torrserver_direct_enabled =
      result.action === 'enable' ? 1 : 0;
    nextSystemInfo.torrserver_direct_active =
      result.action === 'enable' ? 1 : 0;
  }

  const normalizedSystemInfo = normalizeSingBoxVariantFields(nextSystemInfo);

  const notifyActionProviders =
    result.component === 'zapret' ||
    result.component === 'zapret2' ||
    result.component === 'byedpi' ||
    result.component === 'wdtt' ||
    result.component === 'olcrtc' ||
    result.component === 'fptn';

  return {
    nextSystemInfo: normalizedSystemInfo,
    notifyActionProviders,
  };
}
