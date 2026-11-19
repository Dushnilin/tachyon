import { DIAGNOSTICS_CHECKS, DIAGNOSTICS_CHECKS_MAP } from './checks/constants';
import { IDiagnosticsChecksStoreItem, StoreType } from '../../services';

export type ActiveEngine = 'tachyon-core';

/** Returns the engine check code for the given active engine. */
export function getEngineCheckCode(
  _engine: string | undefined,
): DIAGNOSTICS_CHECKS {
  return DIAGNOSTICS_CHECKS.TACHYON_CORE;
}

export interface DiagnosticsProviderOptions {
  activeEngine?: string;
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
  const engineCheck = getEngineCheckCode(options.activeEngine);
  const checks = [DIAGNOSTICS_CHECKS.DNS, engineCheck];

  if (options.includeInbounds === true) {
    checks.push(DIAGNOSTICS_CHECKS.INBOUNDS);
  }

  checks.push(
    DIAGNOSTICS_CHECKS.NFT,
    DIAGNOSTICS_CHECKS.OUTBOUNDS,
    DIAGNOSTICS_CHECKS.FAKEIP,
  );

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
    tachyon_backup_version: '',
    tachyon_backup_time: 0,
    luci_app_version: 'loading',
    tachyon_core_version: 'loading',
    tachyon_core_fptn: 1,
    tachyon_core_tailscale: 1,
    tachyon_core_cert_pin: 1,
    tachyon_core_repo_url: '',
    tachyon_core_backup_version: '',
    tachyon_core_backup_time: 0,
    active_engine: 'tachyon-core',
    server_inbounds_enabled_count: -1,
    direct_bypass_enabled: 0,
    direct_bypass_address: '',
    direct_bypass_port: '',
    torrserver_installed: 0,
    torrserver_version: 'not installed',
    torrserver_running: 0,
    torrserver_direct_available: 0,
    torrserver_direct_enabled: 0,
    torrserver_direct_active: 0,
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
    showTachyonCoreConfig: {
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
    tachyonCoreCheck: { loading: false },
    tachyonCoreInstall: { loading: false },
    tachyonCoreRollback: { loading: false },
    directBypassEnable: { loading: false },
    directBypassDisable: { loading: false },
    torrserverDirectCheck: { loading: false },
    torrserverDirectInstall: { loading: false },
    torrserverDirectRemove: { loading: false },
    torrserverDirectEnable: { loading: false },
    torrserverDirectDisable: { loading: false },
  },
  updatesChecks: {
    tachyon: { status: null, latest_version: '', release_url: '' },
    'tachyon-core': { status: null, latest_version: '', release_url: '' },
    direct_bypass: { status: null, latest_version: '', release_url: '' },
    torrserver_direct: { status: null, latest_version: '', release_url: '' },
  },
};
