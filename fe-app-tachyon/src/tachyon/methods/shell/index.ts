import { callBaseMethod } from './callBaseMethod';
import { ClashAPI, Tachyon } from '../../types';
import { executeShellCommand } from '../../../helpers';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';

const SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS = 15000;
const SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS = 1500;
const UI_ACTION_RPC_TIMEOUT_MS = 15000;
const UI_ACTION_TRANSIENT_RPC_GRACE_MS = 30000;
const SERVICE_ACTION_TIMEOUT_MS = 2 * 60 * 1000;
const SERVICE_ACTION_POLL_INTERVAL_MS = 1000;
const LATENCY_TEST_TIMEOUT_MS = 30 * 1000;
const LATENCY_TEST_POLL_INTERVAL_MS = 1000;
const COMPONENT_ACTION_RPC_TIMEOUT_MS = 10000;
const COMPONENT_ACTION_POLL_INTERVAL_MS = 1000;
const COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS = 2000;
const COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS = 30000;
const COMPONENT_ACTION_MIN_ELAPSED_FOR_SELF_UPDATE_MS = 2000;
const COMPONENT_ACTION_SELF_UPDATE_HARD_TIMEOUT_MS = 120000;
const COMPONENT_ACTION_GENERAL_HARD_TIMEOUT_MS = 15 * 60 * 1000;
const COMPONENT_ACTION_STATE_DIR = '/var/run/tachyon/component-actions';
const GET_UI_STATE_RPC_TIMEOUT_MS = 3000;

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function translate(message: string) {
  return typeof _ === 'function' ? _(message) : message;
}

function parseJsonObjectOutput<T>(output: string): T | null {
  if (!output) {
    return null;
  }

  try {
    return JSON.parse(output) as T;
  } catch (_error) {
    const jsonMatch = output.match(/(\{[\s\S]*\})\s*$/);

    if (!jsonMatch) {
      return null;
    }

    try {
      return JSON.parse(jsonMatch[1]) as T;
    } catch (_jsonError) {
      return null;
    }
  }
}

function parseJsonArrayOutput<T>(output: string): T[] | null {
  if (!output) {
    return null;
  }

  try {
    const parsed = JSON.parse(output);
    if (Array.isArray(parsed)) {
      return parsed as T[];
    }
    return null;
  } catch (_error) {
    const jsonMatch = output.match(/(\[[\s\S]*\])\s*$/);

    if (!jsonMatch) {
      return null;
    }

    try {
      const parsed = JSON.parse(jsonMatch[1]);
      return Array.isArray(parsed) ? (parsed as T[]) : null;
    } catch (_jsonError) {
      return null;
    }
  }
}

function parseComponentActionOutput(output: string) {
  return parseJsonObjectOutput<Tachyon.ComponentActionResult>(output);
}

function parseComponentActionResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseComponentActionOutput(response.stdout);
}

function parseComponentActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  const parsedResponse = parseComponentActionResult(response);

  if (!parsedResponse) {
    return null;
  }

  return parsedResponse as unknown as Tachyon.ComponentActionStartResult;
}

function parseSubscriptionUpdateStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Tachyon.SubscriptionUpdateStartResult>(
    response.stdout,
  );
}

function parseSubscriptionUpdateJobState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Tachyon.SubscriptionUpdateJobState>(
    response.stdout,
  );
}

function parseUiActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Tachyon.UiActionStartResult>(response.stdout);
}

function parseServiceActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Tachyon.ServiceActionState>(response.stdout);
}

function parseLatencyActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Tachyon.LatencyActionState>(response.stdout);
}

function isComponentActionJobId(jobId: string) {
  return /^[A-Za-z0-9._-]+$/.test(jobId) && jobId !== '.' && jobId !== '..';
}

async function readComponentActionState(jobId: string) {
  if (!isComponentActionJobId(jobId)) {
    return null;
  }

  try {
    return parseComponentActionOutput(
      await fs.read(`${COMPONENT_ACTION_STATE_DIR}/${jobId}.json`),
    );
  } catch (_error) {
    return null;
  }
}

async function readTachyonVersion() {
  const response = await executeShellCommand({
    command: '/usr/bin/tachyon',
    args: ['show_version'],
    timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
  });

  if ((response.code ?? 0) !== 0 || !response.stdout) {
    return '';
  }

  return response.stdout.trim();
}

async function isComponentActionStillRunning(
  jobId: string,
  component: Tachyon.ComponentName,
  action: Tachyon.ComponentAction,
) {
  const response = await callBaseMethod<Tachyon.UiState>(
    Tachyon.AvailableMethods.GET_UI_STATE,
    [],
    '/usr/bin/tachyon',
    { timeout: GET_UI_STATE_RPC_TIMEOUT_MS },
  );

  return (
    response.success &&
    response.data.actions.component.some(
      (state) =>
        state.job_id === jobId &&
        state.component === component &&
        state.action === action &&
        state.running,
    )
  );
}

function componentActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: Pick<Tachyon.ComponentActionResult, 'message'> | null,
) {
  return {
    success: false,
    error: parsedResponse?.message || response.stderr || _('Failed to execute'),
  } as Tachyon.MethodFailureResponse;
}

function uiActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: { message?: string } | null,
  fallback: string = _('Failed to execute'),
) {
  return {
    success: false,
    error: parsedResponse?.message || response.stderr || fallback,
  } as Tachyon.MethodFailureResponse;
}

function createTransientRpcGraceTracker(graceMs: number) {
  let failureStartedAt = 0;

  return {
    reset() {
      failureStartedAt = 0;
    },
    shouldContinue(error?: string) {
      if (!isTransientRpcError(error)) {
        failureStartedAt = 0;
        return false;
      }

      if (!failureStartedAt) {
        failureStartedAt = Date.now();
      }

      return Date.now() - failureStartedAt < graceMs;
    },
  };
}

export const TachyonShellMethods = {
  checkDNSAvailable: async () =>
    callBaseMethod<Tachyon.DnsCheckResult>(
      Tachyon.AvailableMethods.CHECK_DNS_AVAILABLE,
    ),
  checkFakeIP: async () =>
    callBaseMethod<Tachyon.FakeIPCheckResult>(
      Tachyon.AvailableMethods.CHECK_FAKEIP,
    ),
  checkNftRules: async () =>
    callBaseMethod<Tachyon.NftRulesCheckResult>(
      Tachyon.AvailableMethods.CHECK_NFT_RULES,
    ),
  checkZapretRuntime: async () =>
    callBaseMethod<Tachyon.ZapretCheckResult>(
      Tachyon.AvailableMethods.CHECK_ZAPRET_RUNTIME,
    ),
  checkZapret2Runtime: async () =>
    callBaseMethod<Tachyon.Zapret2CheckResult>(
      Tachyon.AvailableMethods.CHECK_ZAPRET2_RUNTIME,
    ),
  checkByedpiRuntime: async () =>
    callBaseMethod<Tachyon.ByedpiCheckResult>(
      Tachyon.AvailableMethods.CHECK_BYEDPI_RUNTIME,
    ),
  checkInboundsConfig: async () =>
    callBaseMethod<Tachyon.InboundsConfigCheckResult>(
      Tachyon.AvailableMethods.CHECK_INBOUNDS_CONFIG,
    ),
  getStatus: async () =>
    callBaseMethod<Tachyon.GetStatus>(Tachyon.AvailableMethods.GET_STATUS),
  getOutboundMetadata: async (section: string) =>
    callBaseMethod<Tachyon.GetOutboundMetadata>(
      Tachyon.AvailableMethods.GET_OUTBOUND_METADATA,
      [section],
    ),
  getSubscriptionMetadata: async (section: string) =>
    callBaseMethod<
      Tachyon.SubscriptionMetadata | Tachyon.SubscriptionMetadata[]
    >(Tachyon.AvailableMethods.GET_SUBSCRIPTION_METADATA, [section]),
  checkSingBox: async () =>
    callBaseMethod<Tachyon.SingBoxCheckResult>(
      Tachyon.AvailableMethods.CHECK_SING_BOX,
    ),
  checkInbounds: async () =>
    callBaseMethod<Tachyon.InboundsCheckResult>(
      Tachyon.AvailableMethods.CHECK_INBOUNDS,
    ),
  getSingBoxStatus: async () =>
    callBaseMethod<Tachyon.GetSingBoxStatus>(
      Tachyon.AvailableMethods.GET_SING_BOX_STATUS,
      [],
      '/usr/bin/tachyon',
      { allowNonZeroWithStdout: true },
    ),
  getTailscalePeers: async () =>
    callBaseMethod<Tachyon.GetTailscalePeers>(
      Tachyon.AvailableMethods.GET_TAILSCALE_PEERS,
      [],
      '/usr/bin/tachyon',
      { allowNonZeroWithStdout: true },
    ),
  getZapretStatus: async () =>
    callBaseMethod<Tachyon.GetZapretStatus>(
      Tachyon.AvailableMethods.GET_ZAPRET_STATUS,
      [],
      '/usr/bin/tachyon',
      { allowNonZeroWithStdout: true },
    ),
  getZapret2Status: async () =>
    callBaseMethod<Tachyon.GetZapret2Status>(
      Tachyon.AvailableMethods.GET_ZAPRET2_STATUS,
      [],
      '/usr/bin/tachyon',
      { allowNonZeroWithStdout: true },
    ),
  getByedpiStatus: async () =>
    callBaseMethod<Tachyon.GetByedpiStatus>(
      Tachyon.AvailableMethods.GET_BYEDPI_STATUS,
      [],
      '/usr/bin/tachyon',
      { allowNonZeroWithStdout: true },
    ),
  getClashApiProxies: async () =>
    callBaseMethod<ClashAPI.Proxies>(Tachyon.AvailableMethods.CLASH_API, [
      Tachyon.AvailableClashAPIMethods.GET_PROXIES,
    ]),
  getClashApiConnections: async () =>
    callBaseMethod<unknown>(Tachyon.AvailableMethods.CLASH_API, [
      Tachyon.AvailableClashAPIMethods.GET_CONNECTIONS,
    ]),
  getClashApiProxyLatency: async (tag: string, timeout = '5000') =>
    callBaseMethod<Tachyon.GetClashApiProxyLatency>(
      Tachyon.AvailableMethods.CLASH_API,
      [Tachyon.AvailableClashAPIMethods.GET_PROXY_LATENCY, tag, timeout],
    ),
  getClashApiProxyLatencies: async (tags: string[]) =>
    callBaseMethod<Tachyon.GetClashApiProxyLatencies>(
      Tachyon.AvailableMethods.CLASH_API,
      [
        Tachyon.AvailableClashAPIMethods.GET_PROXY_LATENCIES,
        JSON.stringify(tags),
        '5000',
      ],
    ),
  getClashApiGroupLatency: async (tag: string) =>
    callBaseMethod<Tachyon.GetClashApiGroupLatency>(
      Tachyon.AvailableMethods.CLASH_API,
      [Tachyon.AvailableClashAPIMethods.GET_GROUP_LATENCY, tag, '10000'],
    ),
  setClashApiGroupProxy: async (group: string, proxy: string) =>
    callBaseMethod<unknown>(Tachyon.AvailableMethods.CLASH_API, [
      Tachyon.AvailableClashAPIMethods.SET_GROUP_PROXY,
      group,
      proxy,
    ]),
  closeClashApiConnection: async (connectionId: string) =>
    callBaseMethod<unknown>(Tachyon.AvailableMethods.CLASH_API, [
      Tachyon.AvailableClashAPIMethods.CLOSE_CONNECTION,
      connectionId,
    ]),
  closeAllClashApiConnections: async () =>
    callBaseMethod<unknown>(Tachyon.AvailableMethods.CLASH_API, [
      Tachyon.AvailableClashAPIMethods.CLOSE_ALL_CONNECTIONS,
    ]),
  enable: async () =>
    callBaseMethod<unknown>(
      Tachyon.AvailableMethods.ENABLE,
      [],
      '/etc/init.d/tachyon',
    ),
  disable: async () =>
    callBaseMethod<unknown>(
      Tachyon.AvailableMethods.DISABLE,
      [],
      '/etc/init.d/tachyon',
    ),
  globalCheck: async (masked = true) =>
    callBaseMethod<unknown>(Tachyon.AvailableMethods.GLOBAL_CHECK, [
      masked ? 'masked' : 'raw',
    ]),
  doctor: async () =>
    callBaseMethod<string>(
      Tachyon.AvailableMethods.DOCTOR,
      [],
      '/usr/bin/tachyon',
      { timeout: 30000 },
    ),
  aiDoctor: async () =>
    callBaseMethod<unknown>(
      Tachyon.AvailableMethods.AI_DOCTOR,
      [],
      '/usr/bin/tachyon',
      { timeout: 60000 },
    ),
  aiDoctorLast: async () =>
    callBaseMethod<unknown>(
      Tachyon.AvailableMethods.AI_DOCTOR_LAST,
      [],
      '/usr/bin/tachyon',
      { timeout: 10000 },
    ),
  applyQuickFix: async (fixCode: string) =>
    callBaseMethod<unknown>(
      Tachyon.AvailableMethods.APPLY_QUICK_FIX,
      [fixCode],
      '/usr/bin/tachyon',
      { timeout: 30000 },
    ),
  getLanClients: async () =>
    callBaseMethod<{
      success: boolean;
      clients: Tachyon.LanClient[];
      total: number;
    }>(Tachyon.AvailableMethods.LAN_CLIENTS, [], '/usr/bin/tachyon', {
      timeout: 10000,
    }),
  toggleClientBypass: async (ip: string) =>
    callBaseMethod<{
      success: boolean;
      ip: string;
      mode: 'proxied' | 'direct';
      message: string;
    }>(
      Tachyon.AvailableMethods.TOGGLE_CLIENT_BYPASS,
      [ip],
      '/usr/bin/tachyon',
      { timeout: 15000 },
    ),
  showSingBoxConfig: async (masked = true) =>
    callBaseMethod<unknown>(Tachyon.AvailableMethods.SHOW_SING_BOX_CONFIG, [
      masked ? 'masked' : 'raw',
    ]),
  checkLogs: async () =>
    callBaseMethod<unknown>(Tachyon.AvailableMethods.CHECK_LOGS),
  checkSingBoxLogs: async () =>
    callBaseMethod<unknown>(Tachyon.AvailableMethods.CHECK_SING_BOX_LOGS),
  getSystemInfo: async () =>
    callBaseMethod<Tachyon.GetSystemInfo>(
      Tachyon.AvailableMethods.GET_SYSTEM_INFO,
    ),
  getServerCapabilities: async () =>
    callBaseMethod<Tachyon.GetServerCapabilities>(
      Tachyon.AvailableMethods.GET_SERVER_CAPABILITIES,
    ),
  getUiCapabilities: async () =>
    callBaseMethod<Tachyon.GetUiCapabilities>(
      Tachyon.AvailableMethods.GET_UI_CAPABILITIES,
    ),
  getUiState: async () =>
    callBaseMethod<Tachyon.UiState>(
      Tachyon.AvailableMethods.GET_UI_STATE,
      [],
      '/usr/bin/tachyon',
      { timeout: GET_UI_STATE_RPC_TIMEOUT_MS },
    ),
  serviceActionStart: async (action: Tachyon.ServiceAction) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.SERVICE_ACTION_ASYNC, action],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Service action failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.UiActionStartResult>;
  },
  serviceActionStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.SERVICE_ACTION_STATUS, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseServiceActionState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Service action failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.ServiceActionState>;
  },
  waitServiceActionJob: async (jobId: string, startedAt = Date.now()) => {
    while (Date.now() - startedAt < SERVICE_ACTION_TIMEOUT_MS) {
      await sleep(SERVICE_ACTION_POLL_INTERVAL_MS);

      const response = await TachyonShellMethods.serviceActionStatus(jobId);

      if (!response.success) {
        return response;
      }

      if (response.data.running) {
        continue;
      }

      return response;
    }

    return {
      success: false,
      error: _('Operation timed out'),
    } as Tachyon.MethodFailureResponse;
  },
  latencyTestStart: async (
    latencyType: Tachyon.LatencyActionState['latency_type'],
    section: string,
    tag: string,
    timeout?: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [
        Tachyon.AvailableMethods.LATENCY_TEST_ASYNC,
        latencyType,
        section,
        tag,
        ...(timeout ? [timeout] : []),
      ],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Latency test failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.UiActionStartResult>;
  },
  latencyTestStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.LATENCY_TEST_STATUS, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseLatencyActionState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Latency test failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.LatencyActionState>;
  },
  waitLatencyTestJob: async (jobId: string, startedAt = Date.now()) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (Date.now() - startedAt < LATENCY_TEST_TIMEOUT_MS) {
      await sleep(LATENCY_TEST_POLL_INTERVAL_MS);

      const response = await TachyonShellMethods.latencyTestStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }

    return {
      success: false,
      error: _('Operation timed out'),
    } as Tachyon.MethodFailureResponse;
  },
  uiActionAck: async (
    kind: 'service' | 'latency' | 'component' | 'subscription',
    jobId: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.UI_ACTION_ACK, kind, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse?.success) {
      return uiActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.UiActionStartResult>;
  },
  componentActionStart: async (
    component: Tachyon.ComponentName,
    action: Tachyon.ComponentAction,
    targetVersion?: string,
  ) => {
    const args: string[] = [
      Tachyon.AvailableMethods.COMPONENT_ACTION_ASYNC,
      component,
      action,
    ];
    if (targetVersion) {
      args.push(targetVersion);
    }
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args,
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseComponentActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return componentActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.ComponentActionStartResult>;
  },
  componentActionStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseComponentActionResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return componentActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.ComponentActionResult>;
  },
  componentActionLog: async (jobId: string, offset = 0) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [
        Tachyon.AvailableMethods.COMPONENT_ACTION_LOG,
        jobId,
        String(Math.max(0, Math.floor(offset))),
      ],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse =
      parseJsonObjectOutput<Tachyon.ComponentActionLogResult>(response.stdout);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return {
        success: false,
        error:
          parsedResponse?.success === false
            ? _('Operation log is not available')
            : response.stderr || _('Failed to read operation log'),
      } as Tachyon.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.ComponentActionLogResult>;
  },
  componentUpdateCheckCache: async () =>
    callBaseMethod<Tachyon.ComponentUpdateCheckCache>(
      Tachyon.AvailableMethods.COMPONENT_UPDATE_CHECK_CACHE,
    ),
  componentListReleases: async (
    component: Tachyon.ComponentName,
    count = 3,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [
        Tachyon.AvailableMethods.COMPONENT_LIST_RELEASES,
        component,
        String(count),
      ],
      timeout: 25_000,
    });
    const parsed = parseJsonArrayOutput<Tachyon.ComponentRelease>(
      response.stdout,
    );

    if ((response.code ?? 0) !== 0 || !parsed) {
      return {
        success: false,
        error: response.stderr || _('Failed to fetch releases'),
      } as Tachyon.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsed,
    } as Tachyon.MethodSuccessResponse<Tachyon.ComponentRelease[]>;
  },
  componentInstallVersion: async (
    component: Tachyon.ComponentName,
    tag: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [
        Tachyon.AvailableMethods.COMPONENT_INSTALL_VERSION,
        component,
        tag,
      ],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsed = parseJsonObjectOutput<Tachyon.ComponentActionResult>(
      response.stdout,
    );

    if ((response.code ?? 0) !== 0 || !parsed) {
      return {
        success: false,
        error: response.stderr || _('Failed to install version'),
      } as Tachyon.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsed,
    } as Tachyon.MethodSuccessResponse<Tachyon.ComponentActionResult>;
  },
  waitComponentActionJob: async (
    jobId: string,
    component: Tachyon.ComponentName,
    action: Tachyon.ComponentAction,
    expectedLatestVersion?: string,
  ) => {
    const jobStartedAt = Date.now();
    const isSelfUpdate =
      component === 'tachyon' &&
      (action === 'install' || action === 'reinstall');
    const targetVersion = expectedLatestVersion || '';
    // Version before the update started: confirms an install even when the
    // expected target version is unknown.
    let baselineVersion = '';
    if (isSelfUpdate) {
      baselineVersion = await readTachyonVersion();
    }
    let selfUpdateVersionMatchedAt = 0;
    const transientRpc = createTransientRpcGraceTracker(
      COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    const versionsMatch = (a: string, b: string) => {
      const cleanA = a.replace(/^v/i, '').trim();
      const cleanB = b.replace(/^v/i, '').trim();
      return cleanA === cleanB;
    };

    const isDifferentVersion = Boolean(
      targetVersion && !versionsMatch(targetVersion, baselineVersion),
    );

    // A self-update restarts the service mid-worker: the worker can die
    // before writing its result, the state file can stay "running" forever
    // (recycled pid), and RPC can go away during the swap. The installed
    // version is the only reliable ground truth when upgrading across versions.
    const confirmedByVersion = async () => {
      if (!isSelfUpdate) return '';
      if (
        Date.now() - jobStartedAt <
        COMPONENT_ACTION_MIN_ELAPSED_FOR_SELF_UPDATE_MS
      ) {
        return '';
      }
      const version = await readTachyonVersion();
      if (!version) return '';
      if (isDifferentVersion && versionsMatch(version, targetVersion)) {
        return version;
      }
      if (
        !targetVersion &&
        baselineVersion &&
        !versionsMatch(version, baselineVersion)
      ) {
        return version;
      }
      return '';
    };

    // A reinstall of the same version never changes the version string, so
    // version-based confirmation can never match. Equality with the baseline
    // is the confirmation — but only once the job is no longer running and only
    // when target version matches baseline (or is unspecified).
    const confirmedSameVersionReinstall = async () => {
      if (!isSelfUpdate || !baselineVersion) {
        return '';
      }
      if (targetVersion && !versionsMatch(targetVersion, baselineVersion)) {
        return '';
      }
      const version = await readTachyonVersion();
      if (version && versionsMatch(version, baselineVersion)) {
        return version;
      }
      return '';
    };

    // Version confirmation must be stable for a short settle window: the
    // package files are replaced mid-install, and a read can catch a moment
    // where the new version is already visible but the install is not over.
    const settleVersion = async (version: string) => {
      if (!selfUpdateVersionMatchedAt) {
        selfUpdateVersionMatchedAt = Date.now();
        return false;
      }
      if (
        Date.now() - selfUpdateVersionMatchedAt <
        COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS
      ) {
        return false;
      }
      if (isDifferentVersion) {
        if ((await confirmedByVersion()) === version) {
          return true;
        }
      } else {
        if ((await confirmedSameVersionReinstall()) === version) {
          return true;
        }
      }
      selfUpdateVersionMatchedAt = 0;
      return false;
    };

    const selfUpdateResult = (installedVersion: string) =>
      ({
        success: true,
        data: {
          success: true,
          component,
          action,
          message: translate('Tachyon has been installed'),
          current_version: installedVersion,
          latest_version: expectedLatestVersion,
          changed: true,
          status: 'latest',
        },
      }) as Tachyon.MethodSuccessResponse<Tachyon.ComponentActionResult>;

    const jobDoneResult = (
      data: Tachyon.ComponentActionResult,
    ): Tachyon.MethodSuccessResponse<Tachyon.ComponentActionResult> => ({
      success: true,
      data,
    });

    while (true) {
      await sleep(COMPONENT_ACTION_POLL_INTERVAL_MS);

      const stateResponse = await readComponentActionState(jobId);

      // Hard ceiling: the modal must never hang forever. Report whatever we
      // actually know and close it.
      if (
        isSelfUpdate &&
        Date.now() - jobStartedAt >=
          COMPONENT_ACTION_SELF_UPDATE_HARD_TIMEOUT_MS
      ) {
        if (stateResponse && !stateResponse.running) {
          return jobDoneResult(stateResponse);
        }
        const version = await readTachyonVersion();
        if (targetVersion && version && version !== targetVersion) {
          return {
            success: false,
            error: _('Tachyon update did not complete within the timeout'),
          } as Tachyon.MethodFailureResponse;
        }
        return selfUpdateResult(version || baselineVersion);
      }

      if (
        !isSelfUpdate &&
        Date.now() - jobStartedAt >= COMPONENT_ACTION_GENERAL_HARD_TIMEOUT_MS
      ) {
        if (stateResponse && !stateResponse.running) {
          return jobDoneResult(stateResponse);
        }
        return {
          success: false,
          error: _('Component action timed out'),
        } as Tachyon.MethodFailureResponse;
      }

      // The job is over according to the state file.
      if (stateResponse && !stateResponse.running) {
        if (isSelfUpdate && stateResponse.success === false) {
          const version =
            (await confirmedByVersion()) ||
            (await confirmedSameVersionReinstall());
          if (version) {
            if (await settleVersion(version)) {
              return selfUpdateResult(version);
            }
            continue;
          }
        }
        return jobDoneResult(stateResponse);
      }

      const statusResponse = await executeShellCommand({
        command: '/usr/bin/tachyon',
        args: [Tachyon.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
        timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
      });
      const parsedResponse = parseComponentActionResult(statusResponse);

      if ((statusResponse.code ?? 0) !== 0 || !parsedResponse) {
        if (isSelfUpdate) {
          const version =
            (await confirmedByVersion()) ||
            (await confirmedSameVersionReinstall());
          if (version) {
            if (await settleVersion(version)) {
              return selfUpdateResult(version);
            }
            continue;
          }

          // A self-update replaces the package mid-flight: RPC failures are
          // expected during the swap window and must not fail the operation.
          transientRpc.reset();
          continue;
        }

        if (stateResponse?.running) {
          transientRpc.reset();
          continue;
        }

        if (await isComponentActionStillRunning(jobId, component, action)) {
          transientRpc.reset();
          continue;
        }

        const failure = componentActionFailure(statusResponse, parsedResponse);

        if (transientRpc.shouldContinue(failure.error)) {
          continue;
        }

        return failure;
      }

      transientRpc.reset();
      if (parsedResponse.running) {
        continue;
      }

      if (isSelfUpdate && parsedResponse.success === false) {
        const version =
          (await confirmedByVersion()) ||
          (await confirmedSameVersionReinstall());
        if (version) {
          if (await settleVersion(version)) {
            return selfUpdateResult(version);
          }
          continue;
        }
      }

      return jobDoneResult(parsedResponse);
    }
  },
  subscriptionUpdateStart: async (section?: string, sourceIndex?: number) => {
    const startArgs = [
      Tachyon.AvailableMethods.SUBSCRIPTION_UPDATE_ASYNC,
      ...(section ? [section] : []),
      ...(section && sourceIndex !== undefined ? [String(sourceIndex)] : []),
    ];
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: startArgs,
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseSubscriptionUpdateStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return {
        success: false,
        error:
          parsedResponse?.message ||
          response.stderr ||
          _('Subscription update failed'),
      } as Tachyon.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.SubscriptionUpdateStartResult>;
  },
  subscriptionUpdateStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.SUBSCRIPTION_UPDATE_STATUS, jobId],
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseSubscriptionUpdateJobState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return {
        success: false,
        error: response.stderr || _('Subscription update failed'),
      } as Tachyon.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Tachyon.MethodSuccessResponse<Tachyon.SubscriptionUpdateJobState>;
  },
  waitSubscriptionUpdateJob: async (jobId: string) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (true) {
      await sleep(SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS);

      const response =
        await TachyonShellMethods.subscriptionUpdateStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }
  },

  getWatchdogStatus: async () => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: ['watchdog', 'status'],
      timeout: 5000,
    });
    return {
      success: true,
      data: { running: (response.code ?? 1) === 0 },
    } as Tachyon.MethodSuccessResponse<{ running: boolean }>;
  },

  watchdogStart: async () => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: ['watchdog_start'],
      timeout: 8000,
    });
    return {
      success: (response.code ?? 1) === 0,
    } as Tachyon.MethodResponse<void>;
  },

  watchdogStop: async () => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: ['watchdog_stop'],
      timeout: 8000,
    });
    return {
      success: (response.code ?? 1) === 0,
    } as Tachyon.MethodResponse<void>;
  },

  /**
   * Run an arbitrary UCI command via shell — used for saving Smart Detect
   * settings and per-device routing IPs from the Advanced Settings panel.
   */
  uciRunCommand: async (args: string[]) => {
    const response = await executeShellCommand({
      command: '/sbin/uci',
      args,
      timeout: 5000,
    });
    return {
      success: (response.code ?? 1) === 0,
    } as Tachyon.MethodResponse<void>;
  },

  startFuzzer: async (
    engine: Tachyon.FuzzerEngine = 'zapret2',
    target: Tachyon.FuzzerTarget = 'youtube',
    customUrl?: string,
    ruleSection?: string,
    customFile?: string,
    mode?: Tachyon.FuzzerMode | string,
  ): Promise<Tachyon.MethodResponse<Tachyon.FuzzerStartResponse>> => {
    const args: string[] = [
      Tachyon.AvailableMethods.FUZZER_START,
      engine,
      target,
    ];
    if (customUrl) args.push(customUrl);
    else args.push('');
    if (ruleSection) args.push(ruleSection);
    else args.push('');
    if (customFile) args.push(customFile);
    else args.push('');
    if (mode) args.push(mode);

    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args,
      timeout: 10000,
    });
    let parsed: Tachyon.FuzzerStartResponse | null = null;
    try {
      parsed = JSON.parse(response.stdout?.trim() || '{}');
    } catch {
      parsed = null;
    }
    if ((response.code ?? 1) === 0 && parsed && parsed.success) {
      return {
        success: true,
        data: parsed,
      };
    }
    return {
      success: false,
      error: parsed?.error || response.stderr || _('Failed to start fuzzer'),
    };
  },

  getFuzzerStatus: async (): Promise<
    Tachyon.MethodResponse<Tachyon.FuzzerState>
  > => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.FUZZER_STATUS],
      timeout: 8000,
    });
    let parsed: Tachyon.FuzzerState | null = null;
    try {
      parsed = JSON.parse(response.stdout?.trim() || '{}');
    } catch {
      parsed = null;
    }
    if ((response.code ?? 1) === 0 && parsed) {
      return {
        success: true,
        data: parsed,
      };
    }
    return {
      success: false,
      error: response.stderr || _('Failed to get fuzzer status'),
    };
  },

  stopFuzzer: async (): Promise<Tachyon.MethodResponse<void>> => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.FUZZER_STOP],
      timeout: 8000,
    });
    if ((response.code ?? 1) === 0) {
      return { success: true, data: undefined };
    }
    return {
      success: false,
      error: response.stderr || _('Failed to stop fuzzer'),
    };
  },

  applyFuzzerStrategy: async (
    engine: string,
    args: string,
    targetRuleOrGlobal?: string,
  ): Promise<Tachyon.MethodResponse<Tachyon.FuzzerApplyResponse>> => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [
        Tachyon.AvailableMethods.FUZZER_APPLY,
        engine,
        args,
        targetRuleOrGlobal || 'global',
      ],
      timeout: 10000,
    });
    let parsed: Tachyon.FuzzerApplyResponse | null = null;
    try {
      parsed = JSON.parse(response.stdout?.trim() || '{}');
    } catch {
      parsed = null;
    }
    if ((response.code ?? 1) === 0 && parsed && parsed.success) {
      return {
        success: true,
        data: parsed,
      };
    }
    return {
      success: false,
      error: parsed?.error || response.stderr || _('Failed to apply strategy'),
    };
  },

  getFuzzerStrategies: async (
    mode?: Tachyon.FuzzerMode | string,
  ): Promise<
    Tachyon.MethodResponse<{
      available_engines?: {
        zapret2: boolean;
        zapret: boolean;
        byedpi: boolean;
      };
      zapret2: Tachyon.FuzzerStrategyDefinition[];
      zapret: Tachyon.FuzzerStrategyDefinition[];
      byedpi: Tachyon.FuzzerStrategyDefinition[];
    }>
  > => {
    type FuzzerStrategiesData = {
      available_engines?: {
        zapret2: boolean;
        zapret: boolean;
        byedpi: boolean;
      };
      zapret2: Tachyon.FuzzerStrategyDefinition[];
      zapret: Tachyon.FuzzerStrategyDefinition[];
      byedpi: Tachyon.FuzzerStrategyDefinition[];
    };
    const args: string[] = [Tachyon.AvailableMethods.FUZZER_STRATEGIES];
    if (mode) args.push(mode);

    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args,
      timeout: 8000,
    });
    let parsed: FuzzerStrategiesData | null = null;
    try {
      parsed = JSON.parse(
        response.stdout?.trim() || '{}',
      ) as FuzzerStrategiesData;
    } catch {
      parsed = null;
    }
    if ((response.code ?? 1) === 0 && parsed) {
      return {
        success: true,
        data: parsed,
      };
    }
    return {
      success: false,
      error: response.stderr || _('Failed to get fuzzer strategies'),
    };
  },

  fuzzerAiSynthesize: async (
    engine: string,
    target: string,
    customUrl?: string,
    userPrompt?: string,
  ): Promise<Tachyon.MethodResponse<Tachyon.FuzzerAiSynthesizeResponse>> => {
    const args: string[] = [
      Tachyon.AvailableMethods.FUZZER_AI_SYNTHESIZE,
      engine,
      target,
    ];
    if (customUrl) args.push(customUrl);
    else args.push('');
    if (userPrompt) args.push(userPrompt);

    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args,
      timeout: 65000,
    });

    let parsed: Tachyon.FuzzerAiSynthesizeResponse | null = null;
    try {
      parsed = JSON.parse(
        response.stdout?.trim() || '{}',
      ) as Tachyon.FuzzerAiSynthesizeResponse;
    } catch {
      parsed = null;
    }

    if ((response.code ?? 1) === 0 && parsed && parsed.success) {
      return {
        success: true,
        data: parsed,
      };
    }
    return {
      success: false,
      error:
        parsed?.error ||
        response.stderr ||
        _('Failed to synthesize AI strategies'),
    };
  },

  getFuzzerPatterns: async (): Promise<
    Tachyon.MethodResponse<{ patterns: Tachyon.FuzzerPatternsConfig }>
  > => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.FUZZER_GET_PATTERNS],
      timeout: 8000,
    });

    let parsed: {
      success: boolean;
      patterns: Tachyon.FuzzerPatternsConfig;
    } | null = null;
    try {
      parsed = JSON.parse(response.stdout?.trim() || '{}');
    } catch {
      parsed = null;
    }

    if ((response.code ?? 1) === 0 && parsed && parsed.success) {
      return {
        success: true,
        data: parsed,
      };
    }
    return {
      success: false,
      error: response.stderr || _('Failed to get fuzzer patterns'),
    };
  },

  saveFuzzerPatterns: async (
    patterns: Tachyon.FuzzerPatternsConfig,
  ): Promise<Tachyon.MethodResponse<{ message: string }>> => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [
        Tachyon.AvailableMethods.FUZZER_SAVE_PATTERNS,
        JSON.stringify(patterns),
      ],
      timeout: 10000,
    });

    let parsed: { success: boolean; message?: string; error?: string } | null =
      null;
    try {
      parsed = JSON.parse(response.stdout?.trim() || '{}');
    } catch {
      parsed = null;
    }

    if ((response.code ?? 1) === 0 && parsed && parsed.success) {
      return {
        success: true,
        data: { message: parsed.message || _('Patterns saved successfully') },
      };
    }
    return {
      success: false,
      error:
        parsed?.error || response.stderr || _('Failed to save fuzzer patterns'),
    };
  },

  resetFuzzerPatterns: async (): Promise<
    Tachyon.MethodResponse<{
      patterns: Tachyon.FuzzerPatternsConfig;
      message: string;
    }>
  > => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.FUZZER_RESET_PATTERNS],
      timeout: 8000,
    });

    let parsed: {
      success: boolean;
      message?: string;
      patterns?: Tachyon.FuzzerPatternsConfig;
      error?: string;
    } | null = null;
    try {
      parsed = JSON.parse(response.stdout?.trim() || '{}');
    } catch {
      parsed = null;
    }

    if ((response.code ?? 1) === 0 && parsed && parsed.success) {
      return {
        success: true,
        data: {
          message: parsed.message || _('Patterns reset to factory defaults'),
          patterns: parsed.patterns as Tachyon.FuzzerPatternsConfig,
        },
      };
    }
    return {
      success: false,
      error:
        parsed?.error ||
        response.stderr ||
        _('Failed to reset fuzzer patterns'),
    };
  },

  detectFuzzerDpi: async (target: string, customUrl?: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [
        Tachyon.AvailableMethods.FUZZER_DETECT_DPI,
        target,
        ...(customUrl ? [customUrl] : []),
      ],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsed = parseJsonObjectOutput<Tachyon.FuzzerDetectDpiResponse>(
      response.stdout,
    );

    if ((response.code ?? 0) !== 0 || !parsed) {
      return {
        success: false,
        error: response.stderr || _('Failed to detect DPI type'),
      };
    }
    return {
      success: true,
      data: parsed,
    };
  },

  autoApplyFuzzerStrategy: async (targetRule?: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [
        Tachyon.AvailableMethods.FUZZER_AUTO_APPLY,
        ...(targetRule ? [targetRule] : []),
      ],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsed = parseJsonObjectOutput<Tachyon.FuzzerAutoApplyResponse>(
      response.stdout,
    );

    if ((response.code ?? 0) !== 0 || !parsed?.success) {
      return {
        success: false,
        error:
          parsed?.error ||
          response.stderr ||
          _('Failed to auto-apply strategy'),
      };
    }
    return {
      success: true,
      data: parsed,
    };
  },

  getFuzzerHistory: async (limit?: number) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.FUZZER_HISTORY, String(limit || 20)],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsed = parseJsonObjectOutput<Tachyon.FuzzerHistoryResult>(
      response.stdout,
    );

    if ((response.code ?? 0) !== 0 || !parsed) {
      return {
        success: false,
        error: response.stderr || _('Failed to get fuzzer history'),
      };
    }
    return {
      success: true,
      data: parsed,
    };
  },

  clearFuzzerHistory: async () => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.FUZZER_CLEAR_HISTORY],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsed = parseJsonObjectOutput<{
      success: boolean;
      error?: string;
    }>(response.stdout);

    if ((response.code ?? 0) !== 0 || !parsed?.success) {
      return {
        success: false,
        error: response.stderr || _('Failed to clear fuzzer history'),
      };
    }
    return {
      success: true,
      data: { message: _('History cleared') },
    };
  },

  startDnsBenchmark: async (): Promise<
    Tachyon.MethodResponse<{ message: string; running: boolean }>
  > => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.DNS_BENCHMARK_START],
      timeout: 10000,
    });
    const parsed = parseJsonObjectOutput<{
      success: boolean;
      message: string;
      running: boolean;
      error?: string;
    }>(response.stdout);

    if ((response.code ?? 0) !== 0 || !parsed?.success) {
      return {
        success: false,
        error:
          parsed?.error ||
          response.stderr ||
          _('Failed to start DNS benchmark'),
      };
    }
    return {
      success: true,
      data: { message: parsed.message, running: parsed.running },
    };
  },

  getDnsBenchmarkStatus: async (): Promise<
    Tachyon.MethodResponse<Tachyon.DnsBenchmarkState>
  > => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.DNS_BENCHMARK_STATUS],
      timeout: 8000,
    });
    const parsed = parseJsonObjectOutput<Tachyon.DnsBenchmarkState>(
      response.stdout,
    );

    if ((response.code ?? 0) !== 0 || !parsed) {
      return {
        success: false,
        error: response.stderr || _('Failed to get DNS benchmark status'),
      };
    }
    return {
      success: true,
      data: parsed,
    };
  },

  stopDnsBenchmark: async (): Promise<Tachyon.MethodResponse<void>> => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.DNS_BENCHMARK_STOP],
      timeout: 8000,
    });
    if ((response.code ?? 0) === 0) {
      return { success: true, data: undefined };
    }
    return {
      success: false,
      error: response.stderr || _('Failed to stop DNS benchmark'),
    };
  },

  applyDnsBenchmark: async (): Promise<
    Tachyon.MethodResponse<{
      message: string;
      recommendation?: Tachyon.DnsBenchmarkRecommendation;
    }>
  > => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [Tachyon.AvailableMethods.DNS_BENCHMARK_APPLY],
      timeout: 15000,
    });
    const parsed = parseJsonObjectOutput<{
      success: boolean;
      message?: string;
      error?: string;
      recommendation?: Tachyon.DnsBenchmarkRecommendation;
    }>(response.stdout);

    if ((response.code ?? 0) !== 0 || !parsed?.success) {
      return {
        success: false,
        error:
          parsed?.error ||
          response.stderr ||
          _('Failed to apply DNS configuration'),
      };
    }
    return {
      success: true,
      data: {
        message: parsed.message || _('Configuration applied'),
        recommendation: parsed.recommendation,
      },
    };
  },
};
