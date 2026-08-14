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
const COMPONENT_ACTION_STATUS_REFRESH_INTERVAL_MS = 2000;
const COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS = 2000;
const COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS = 30000;
const COMPONENT_ACTION_MIN_ELAPSED_FOR_SELF_UPDATE_MS = 2000;
const COMPONENT_ACTION_SELF_UPDATE_HARD_TIMEOUT_MS = 120000;
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
        state.running === true,
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
    ),
  getZapretStatus: async () =>
    callBaseMethod<Tachyon.GetZapretStatus>(
      Tachyon.AvailableMethods.GET_ZAPRET_STATUS,
    ),
  getZapret2Status: async () =>
    callBaseMethod<Tachyon.GetZapret2Status>(
      Tachyon.AvailableMethods.GET_ZAPRET2_STATUS,
    ),
  getByedpiStatus: async () =>
    callBaseMethod<Tachyon.GetByedpiStatus>(
      Tachyon.AvailableMethods.GET_BYEDPI_STATUS,
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
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/tachyon',
      args: [
        Tachyon.AvailableMethods.COMPONENT_ACTION_ASYNC,
        component,
        action,
      ],
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
    let lastStatusRefreshAt = 0;
    const transientRpc = createTransientRpcGraceTracker(
      COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    // A self-update restarts the service mid-worker: the worker can die
    // before writing its result, the state file can stay "running" forever
    // (recycled pid), and RPC can go away during the swap. The installed
    // version is the only reliable ground truth.
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
      if (targetVersion && version === targetVersion) {
        return version;
      }
      if (!targetVersion && baselineVersion && version !== baselineVersion) {
        return version;
      }
      return '';
    };

    // A reinstall of the same version never changes the version string, so
    // version-based confirmation can never match. Equality with the baseline
    // is the confirmation — but only once the job is no longer running.
    const confirmedSameVersionReinstall = async () => {
      if (!isSelfUpdate || action !== 'reinstall' || !baselineVersion) {
        return '';
      }
      const version = await readTachyonVersion();
      if (
        version === baselineVersion &&
        (!targetVersion || version === targetVersion)
      ) {
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
      if ((await confirmedByVersion()) === version) {
        return true;
      }
      if (
        version === baselineVersion &&
        (await confirmedSameVersionReinstall()) === version
      ) {
        return true;
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

      // The backend may be stuck reporting the job as running (worker pid
      // recycled by the service restart): confirm by version on each tick.
      if (
        stateResponse &&
        stateResponse.running &&
        isSelfUpdate &&
        Date.now() - lastStatusRefreshAt >=
          COMPONENT_ACTION_STATUS_REFRESH_INTERVAL_MS
      ) {
        const version = await confirmedByVersion();
        if (version && (await settleVersion(version))) {
          return selfUpdateResult(version);
        }
      }

      lastStatusRefreshAt = Date.now();
      const statusResponse = await executeShellCommand({
        command: '/usr/bin/tachyon',
        args: [Tachyon.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
        timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
      });
      const parsedResponse = parseComponentActionResult(statusResponse);

      if ((statusResponse.code ?? 0) !== 0 || !parsedResponse) {
        if (stateResponse?.running) {
          transientRpc.reset();
          continue;
        }

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
          // The version confirmation above is the only exit that matters.
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
        if (isSelfUpdate) {
          const version = await confirmedByVersion();
          if (version && (await settleVersion(version))) {
            return selfUpdateResult(version);
          }
        }
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
};
