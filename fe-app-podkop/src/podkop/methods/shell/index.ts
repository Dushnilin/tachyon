import { callBaseMethod } from './callBaseMethod';
import { ClashAPI, Podkop } from '../../types';
import { executeShellCommand } from '../../../helpers';

const SUBSCRIPTION_UPDATE_TIMEOUT_MS = 10 * 60 * 1000;
const COMPONENT_ACTION_TIMEOUT_MS = 10 * 60 * 1000;
const COMPONENT_ACTION_RPC_TIMEOUT_MS = 15000;
const COMPONENT_ACTION_POLL_INTERVAL_MS = 1500;

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function parseComponentActionResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  if (!response.stdout) {
    return null;
  }

  try {
    return JSON.parse(response.stdout) as Podkop.ComponentActionResult;
  } catch (_error) {
    const jsonMatch = response.stdout.match(/(\{[\s\S]*\})\s*$/);

    if (!jsonMatch) {
      return null;
    }

    try {
      return JSON.parse(jsonMatch[1]) as Podkop.ComponentActionResult;
    } catch (_jsonError) {
      return null;
    }
  }
}

function parseComponentActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  const parsedResponse = parseComponentActionResult(response);

  if (!parsedResponse) {
    return null;
  }

  return parsedResponse as unknown as Podkop.ComponentActionStartResult;
}

function componentActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: Pick<Podkop.ComponentActionResult, 'message'> | null,
) {
  return {
    success: false,
    error:
      parsedResponse?.message ||
      response.stderr ||
      _('Component action failed'),
  } as Podkop.MethodFailureResponse;
}

export const PodkopShellMethods = {
  checkDNSAvailable: async () =>
    callBaseMethod<Podkop.DnsCheckResult>(
      Podkop.AvailableMethods.CHECK_DNS_AVAILABLE,
    ),
  checkFakeIP: async () =>
    callBaseMethod<Podkop.FakeIPCheckResult>(
      Podkop.AvailableMethods.CHECK_FAKEIP,
    ),
  checkNftRules: async () =>
    callBaseMethod<Podkop.NftRulesCheckResult>(
      Podkop.AvailableMethods.CHECK_NFT_RULES,
    ),
  checkZapretRuntime: async () =>
    callBaseMethod<Podkop.ZapretCheckResult>(
      Podkop.AvailableMethods.CHECK_ZAPRET_RUNTIME,
    ),
  checkByedpiRuntime: async () =>
    callBaseMethod<Podkop.ByedpiCheckResult>(
      Podkop.AvailableMethods.CHECK_BYEDPI_RUNTIME,
    ),
  getStatus: async () =>
    callBaseMethod<Podkop.GetStatus>(Podkop.AvailableMethods.GET_STATUS),
  getOutboundLink: async (section: string, tag: string) =>
    callBaseMethod<Podkop.GetOutboundLink>(
      Podkop.AvailableMethods.GET_OUTBOUND_LINK,
      [section, tag],
    ),
  getOutboundLinkStates: async (section: string) =>
    callBaseMethod<Podkop.GetOutboundLinkStates>(
      Podkop.AvailableMethods.GET_OUTBOUND_LINK_STATES,
      [section],
    ),
  getOutboundMetadata: async (section: string) =>
    callBaseMethod<Podkop.GetOutboundMetadata>(
      Podkop.AvailableMethods.GET_OUTBOUND_METADATA,
      [section],
    ),
  getSubscriptionMetadata: async (section: string) =>
    callBaseMethod<Podkop.SubscriptionMetadata | Podkop.SubscriptionMetadata[]>(
      Podkop.AvailableMethods.GET_SUBSCRIPTION_METADATA,
      [section],
    ),
  checkSingBox: async () =>
    callBaseMethod<Podkop.SingBoxCheckResult>(
      Podkop.AvailableMethods.CHECK_SING_BOX,
    ),
  getSingBoxStatus: async () =>
    callBaseMethod<Podkop.GetSingBoxStatus>(
      Podkop.AvailableMethods.GET_SING_BOX_STATUS,
    ),
  getZapretStatus: async () =>
    callBaseMethod<Podkop.GetZapretStatus>(
      Podkop.AvailableMethods.GET_ZAPRET_STATUS,
    ),
  getByedpiStatus: async () =>
    callBaseMethod<Podkop.GetByedpiStatus>(
      Podkop.AvailableMethods.GET_BYEDPI_STATUS,
    ),
  getClashApiProxies: async () =>
    callBaseMethod<ClashAPI.Proxies>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.GET_PROXIES,
    ]),
  getClashApiConnections: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.GET_CONNECTIONS,
    ]),
  getClashApiProxyLatency: async (tag: string) =>
    callBaseMethod<Podkop.GetClashApiProxyLatency>(
      Podkop.AvailableMethods.CLASH_API,
      [Podkop.AvailableClashAPIMethods.GET_PROXY_LATENCY, tag, '5000'],
    ),
  getClashApiGroupLatency: async (tag: string) =>
    callBaseMethod<Podkop.GetClashApiGroupLatency>(
      Podkop.AvailableMethods.CLASH_API,
      [Podkop.AvailableClashAPIMethods.GET_GROUP_LATENCY, tag, '10000'],
    ),
  setClashApiGroupProxy: async (group: string, proxy: string) =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.SET_GROUP_PROXY,
      group,
      proxy,
    ]),
  closeClashApiConnection: async (connectionId: string) =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.CLOSE_CONNECTION,
      connectionId,
    ]),
  closeAllClashApiConnections: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.CLOSE_ALL_CONNECTIONS,
    ]),
  restart: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.RESTART,
      [],
      '/etc/init.d/podkop-plus',
    ),
  start: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.START,
      [],
      '/etc/init.d/podkop-plus',
    ),
  stop: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.STOP,
      [],
      '/etc/init.d/podkop-plus',
    ),
  enable: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.ENABLE,
      [],
      '/etc/init.d/podkop-plus',
    ),
  disable: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.DISABLE,
      [],
      '/etc/init.d/podkop-plus',
    ),
  globalCheck: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.GLOBAL_CHECK),
  showSingBoxConfig: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.SHOW_SING_BOX_CONFIG),
  checkLogs: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CHECK_LOGS),
  checkSingBoxLogs: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CHECK_SING_BOX_LOGS),
  getSystemInfo: async () =>
    callBaseMethod<Podkop.GetSystemInfo>(
      Podkop.AvailableMethods.GET_SYSTEM_INFO,
    ),
  componentAction: async (
    component: Podkop.ComponentName,
    action: Podkop.ComponentAction,
  ) => {
    const startedAt = Date.now();
    const startResponse = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [
        Podkop.AvailableMethods.COMPONENT_ACTION_ASYNC,
        component,
        action,
      ],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });

    const parsedStartResponse = parseComponentActionStartResult(startResponse);

    if (
      (startResponse.code ?? 0) !== 0 ||
      !parsedStartResponse?.success ||
      !parsedStartResponse.job_id
    ) {
      return componentActionFailure(startResponse, parsedStartResponse);
    }

    while (Date.now() - startedAt < COMPONENT_ACTION_TIMEOUT_MS) {
      await sleep(COMPONENT_ACTION_POLL_INTERVAL_MS);

      const statusResponse = await executeShellCommand({
        command: '/usr/bin/podkop-plus',
        args: [
          Podkop.AvailableMethods.COMPONENT_ACTION_STATUS,
          parsedStartResponse.job_id,
        ],
        timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
      });
      const parsedResponse = parseComponentActionResult(statusResponse);

      if ((statusResponse.code ?? 0) !== 0 || parsedResponse?.success === false) {
        return componentActionFailure(statusResponse, parsedResponse);
      }

      if (!parsedResponse) {
        return componentActionFailure(statusResponse);
      }

      if (parsedResponse.running) {
        continue;
      }

      return {
        success: true,
        data: parsedResponse,
      } as Podkop.MethodSuccessResponse<Podkop.ComponentActionResult>;
    }

    return {
      success: false,
      error: _('Component action timed out'),
    } as Podkop.MethodFailureResponse;
  },
  subscriptionUpdate: async (section?: string, sourceIndex?: number) => {
    const args = [
      Podkop.AvailableMethods.SUBSCRIPTION_UPDATE,
      ...(section ? [section] : []),
      ...(section && sourceIndex !== undefined ? [String(sourceIndex)] : []),
    ];
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args,
      timeout: SUBSCRIPTION_UPDATE_TIMEOUT_MS,
    });

    if ((response.code ?? 0) !== 0) {
      return {
        success: false,
        error: response.stderr || _('Subscription update failed'),
      } as Podkop.MethodFailureResponse;
    }

    return {
      success: true,
      data: response.stdout,
    } as Podkop.MethodSuccessResponse<string>;
  },
};
