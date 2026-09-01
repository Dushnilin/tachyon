import {
  DIAGNOSTICS_CHECKS,
  DIAGNOSTICS_CHECKS_MAP,
} from './checks/contstants';
import { IDiagnosticsChecksStoreItem, StoreType } from '../../services';

export interface DiagnosticsProviderOptions {
  includeZapret?: boolean;
  includeZapret2?: boolean;
  includeByedpi?: boolean;
  includeInbounds?: boolean;
}

function createDiagnosticCheck(
  code: DIAGNOSTICS_CHECKS,
  description: string,
): IDiagnosticsChecksStoreItem {
  const meta = DIAGNOSTICS_CHECKS_MAP[code];

  return {
    code,
    title: meta.title,
    order: meta.order,
    description,
    items: [],
    state: 'skipped',
  };
}

export function getDiagnosticsChecks(
  description: string,
  options: DiagnosticsProviderOptions = {},
): Array<IDiagnosticsChecksStoreItem> {
  const checks = [DIAGNOSTICS_CHECKS.DNS, DIAGNOSTICS_CHECKS.SINGBOX];

  if (options.includeInbounds === true) {
    checks.push(DIAGNOSTICS_CHECKS.INBOUNDS);
  }

  checks.push(DIAGNOSTICS_CHECKS.NFT);

  if (options.includeZapret) {
    checks.push(DIAGNOSTICS_CHECKS.ZAPRET);
  }

  if (options.includeZapret2) {
    checks.push(DIAGNOSTICS_CHECKS.ZAPRET2);
  }

  if (options.includeByedpi) {
    checks.push(DIAGNOSTICS_CHECKS.BYEDPI);
  }

  checks.push(DIAGNOSTICS_CHECKS.OUTBOUNDS, DIAGNOSTICS_CHECKS.FAKEIP);

  return checks.map((code) => createDiagnosticCheck(code, description));
}

export function getLoadingDiagnosticsChecks(
  options: DiagnosticsProviderOptions = {},
): Pick<StoreType, 'diagnosticsChecks'> {
  return {
    diagnosticsChecks: getDiagnosticsChecks(_('Pending'), options),
  };
}

export const initialDiagnosticStore: Pick<
  StoreType,
  | 'diagnosticsChecks'
  | 'diagnosticsRunAction'
  | 'diagnosticsActions'
  | 'diagnosticsSystemInfo'
  | 'updatesActions'
  | 'updatesChecks'
> = {
  diagnosticsSystemInfo: {
    loading: true,
    loaded: false,
    providerInfoLoaded: false,
    tachyon_version: 'loading',
    tachyon_commit_sha: '',
    tachyon_latest_version: 'loading',
    luci_app_version: 'loading',
    sing_box_version: 'loading',
    sing_box_extended: 0,
    sing_box_tiny: 0,
    sing_box_compressed: 0,
    sing_box_lx: 0,
    sing_box_tailscale: 1,
    sing_box_repo_url: '',
    sing_box_backup_version: '',
    sing_box_backup_time: 0,
    zapret_version: 'loading',
    zapret_installed: 0,
    zapret_backup_version: '',
    zapret_backup_time: 0,
    zapret2_version: 'loading',
    zapret2_installed: 0,
    zapret2_backup_version: '',
    zapret2_backup_time: 0,
    byedpi_version: 'loading',
    byedpi_installed: 0,
    byedpi_backup_version: '',
    byedpi_backup_time: 0,
    tailscale_version: 'loading',
    tailscale_installed: 0,
    tailscale_backup_version: '',
    tailscale_backup_time: 0,
    server_inbounds_enabled_count: -1,
    openwrt_version: 'loading',
    device_model: 'loading',
  },
  diagnosticsActions: {
    restart: {
      loading: false,
    },
    start: {
      loading: false,
    },
    stop: {
      loading: false,
    },
    enable: {
      loading: false,
    },
    disable: {
      loading: false,
    },
    globalCheck: {
      loading: false,
    },
    doctor: {
      loading: false,
    },
    aiDoctor: {
      loading: false,
    },
    viewLogs: {
      loading: false,
    },
    showSingBoxConfig: {
      loading: false,
    },
    generateBugReport: {
      loading: false,
    },
    checkServices: {
      loading: false,
    },
  },
  diagnosticsRunAction: { loading: false },
  diagnosticsChecks: getDiagnosticsChecks(_('Not running')),
  updatesActions: {
    tachyonCheck: { loading: false },
    tachyonInstall: { loading: false },
    tachyonReinstall: { loading: false },
    tachyonRollback: { loading: false },
    singBoxCheck: { loading: false },
    singBoxInstall: { loading: false },
    singBoxRollback: { loading: false },
    singBoxInstallExtended: { loading: false },
    singBoxInstallExtendedCompressed: { loading: false },
    singBoxInstallLx: { loading: false },
    singBoxInstallTiny: { loading: false },
    singBoxInstallStable: { loading: false },
    zapretCheck: { loading: false },
    zapretInstall: { loading: false },
    zapretRemove: { loading: false },
    zapretRollback: { loading: false },
    zapret2Check: { loading: false },
    zapret2Install: { loading: false },
    zapret2Remove: { loading: false },
    zapret2Rollback: { loading: false },
    byedpiCheck: { loading: false },
    byedpiInstall: { loading: false },
    byedpiRemove: { loading: false },
    byedpiRollback: { loading: false },
    tailscaleCheck: { loading: false },
    tailscaleInstall: { loading: false },
    tailscaleRemove: { loading: false },
    tailscaleRollback: { loading: false },
  },
  updatesChecks: {
    tachyon: { status: null, latest_version: '', release_url: '' },
    sing_box: { status: null, latest_version: '', release_url: '' },
    zapret: { status: null, latest_version: '', release_url: '' },
    zapret2: { status: null, latest_version: '', release_url: '' },
    byedpi: { status: null, latest_version: '', release_url: '' },
    tailscale: { status: null, latest_version: '', release_url: '' },
  },
};
