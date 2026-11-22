import { DIAGNOSTICS_CHECKS_MAP } from './constants';
import { TachyonShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { getDashboardSections } from '../../../methods/custom/getDashboardSections';
import { tr } from '../../../helpers/i18n';
import { IDiagnosticsChecksItem } from '../../../services';

type SectionCheckState = IDiagnosticsChecksItem['state'];

function getSubscriptionLatencyState(
  latencyValues: unknown[],
): SectionCheckState {
  const hasAvailableLatency = latencyValues.some((item) => Boolean(item));
  const hasUnavailableLatency = latencyValues.some((item) => !item);

  if (!hasAvailableLatency) {
    return 'error';
  }

  if (hasUnavailableLatency) {
    return 'warning';
  }

  return 'success';
}

/**
 * The reason a latency test failed, when the answer carries one.
 *
 * Our own core answers with the reason beside the message. If an answer
 * omits a reason, there is nothing to show, and its generic message is not
 * one: it names no cause.
 */
function readLatencyReason(data: unknown): string {
  if (!data || typeof data !== 'object') return '';
  const payload = data as { reason?: unknown; message?: unknown };
  if (typeof payload.reason === 'string' && payload.reason.trim()) {
    return payload.reason.trim();
  }
  return '';
}

function extractResponseData(
  response: unknown,
): Record<string, unknown> | null {
  if (!response || typeof response !== 'object' || !('data' in response)) {
    return null;
  }
  const data = (response as { data?: unknown }).data;
  return data && typeof data === 'object'
    ? (data as Record<string, unknown>)
    : null;
}

function extractPositiveLatencyDelay(response: unknown): number | null {
  if (!response || typeof response !== 'object') {
    return null;
  }
  if (!(response as { success?: unknown }).success) {
    return null;
  }
  const data = extractResponseData(response);
  if (!data || data.message) {
    return null;
  }
  const directDelay = data.delay;
  if (typeof directDelay === 'number' && directDelay > 0) {
    return directDelay;
  }
  const groupDelays = Object.values(data).filter(
    (v): v is number => typeof v === 'number' && v > 0,
  );
  if (groupDelays.length > 0) {
    return Math.min(...groupDelays);
  }
  return null;
}

async function probeOutboundWithLiveRetry(
  primaryCode: string,
  fallbackCode?: string,
  configuredTimeout?: string,
) {
  const primaryResp = await TachyonShellMethods.getClashApiProxyLatency(
    primaryCode,
    configuredTimeout,
  );
  const primaryDelay = extractPositiveLatencyDelay(primaryResp);
  if (primaryDelay !== null) {
    return { delay: primaryDelay, reason: '' };
  }

  const parsedConfigured = Number(configuredTimeout);
  const retryTimeout = String(
    Math.max(
      Number.isFinite(parsedConfigured) && parsedConfigured > 0
        ? parsedConfigured
        : 8000,
      10000,
    ),
  );

  const retryResp = await TachyonShellMethods.getClashApiProxyLatency(
    primaryCode,
    retryTimeout,
  );
  const retryDelay = extractPositiveLatencyDelay(retryResp);
  if (retryDelay !== null) {
    return { delay: retryDelay, reason: '' };
  }

  let lastResponse: unknown = retryResp || primaryResp;
  if (fallbackCode && fallbackCode !== primaryCode) {
    const fallbackResp = await TachyonShellMethods.getClashApiProxyLatency(
      fallbackCode,
      retryTimeout,
    );
    const fallbackDelay = extractPositiveLatencyDelay(fallbackResp);
    if (fallbackDelay !== null) {
      return { delay: fallbackDelay, reason: '' };
    }
    if (fallbackResp) {
      lastResponse = fallbackResp;
    }
  }

  return {
    delay: null,
    reason: readLatencyReason(extractResponseData(lastResponse)),
  };
}

export async function runSectionsCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.OUTBOUNDS;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const sections = await getDashboardSections({
    includeSubscriptionCopyState: false,
  });

  if (!sections.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Rule outbounds checks failed');
  }

  const items: Array<IDiagnosticsChecksItem> = [];

  for (const section of sections.data) {
    async function getLatency(): Promise<{
      state: SectionCheckState;
      latency: string;
    }> {
      if (section.withTagSelect) {
        const selectedOutbound =
          section.outbounds.find((item) => item.selected) ??
          section.outbounds.find(
            (item) => item.type?.toLowerCase() === 'urltest',
          ) ??
          section.outbounds[0];

        const isSubscription = section.proxyConfigType === 'subscription';

        const activeNodeCode =
          selectedOutbound?.urlTestInfo?.selectedCode ||
          selectedOutbound?.priorityInfo?.selectedCode ||
          selectedOutbound?.code;

        if (activeNodeCode) {
          const fallbackCode =
            selectedOutbound?.code && selectedOutbound.code !== activeNodeCode
              ? selectedOutbound.code
              : undefined;
          const { delay: liveDelay, reason } = await probeOutboundWithLiveRetry(
            activeNodeCode,
            fallbackCode,
            section.latencyTestTimeout,
          );

          if (liveDelay !== null) {
            return {
              state: 'success',
              latency: `[${selectedOutbound?.displayName ?? ''}] ${liveDelay}ms`,
            };
          }

          if (selectedOutbound?.latency && selectedOutbound.latency > 0) {
            return {
              state: 'success',
              latency: `[${selectedOutbound.displayName ?? ''}] ${selectedOutbound.latency}ms`,
            };
          }

          return {
            state: 'error',
            latency: reason
              ? `[${selectedOutbound?.displayName ?? ''}] ${_('Not responding')}: ${reason}`
              : `[${selectedOutbound?.displayName ?? ''}] ${_('Not responding')}`,
          };
        }

        const latencyGroup = await TachyonShellMethods.getClashApiGroupLatency(
          section.code,
        );
        const success = latencyGroup.success && !latencyGroup.data?.message;

        if (success) {
          const latencyValues = Object.values(latencyGroup.data);
          const sectionState = isSubscription
            ? getSubscriptionLatencyState(latencyValues)
            : 'success';

          const selectedProxyDelay =
            latencyGroup.data?.[selectedOutbound?.code ?? ''];

          if (typeof selectedProxyDelay === 'number') {
            return {
              state: sectionState,
              latency: `[${selectedOutbound?.displayName ?? ''}] ${selectedProxyDelay}ms`,
            };
          }

          // The core answers a failed latency test with the reason beside the
          // message. "Not responding" on its own leaves the user with nothing
          // to act on; a core without a reason simply shows the message.
          const reason = readLatencyReason(latencyGroup.data);
          return {
            state: 'error',
            latency: reason
              ? `[${selectedOutbound?.displayName ?? ''}] ${_('Not responding')}: ${reason}`
              : `[${selectedOutbound?.displayName ?? ''}] ${_('Not responding')}`,
          };
        }

        return {
          state: 'error',
          latency: _('Not responding'),
        };
      }

      const actionLower = (section.action || '').toLowerCase();
      if (actionLower === 'block' || actionLower === 'reject') {
        return {
          state: 'success',
          latency: tr('Активно (Блокировка)', 'Active (Block)'),
        };
      }
      if (actionLower === 'bypass' || actionLower === 'direct') {
        return {
          state: 'success',
          latency: tr('Активно (Напрямую)', 'Active (Direct)'),
        };
      }
      if (actionLower === 'dns') {
        return {
          state: 'success',
          latency: tr('Активно (DNS)', 'Active (DNS)'),
        };
      }
      if (actionLower === 'desync') {
        const selectedOut = section.outbounds?.[0];
        if (selectedOut && selectedOut.runtimeAvailable === false) {
          return {
            state: 'error',
            latency: tr('Не настроено', 'Not configured'),
          };
        }
        return {
          state: 'success',
          latency: tr('Активно (DPI)', 'Active (DPI)'),
        };
      }

      // Service sections (e.g. fptn) don't have Clash API proxies.
      // Use the serviceStatus that was already fetched in getDashboardSections.
      const isService = Boolean(section.serviceStatus);

      if (isService) {
        if (section.serviceStatus) {
          const s = section.serviceStatus;
          if (s.ready) {
            return {
              state: 'success',
              latency: _('Running'),
            };
          }
          if (s.conflict) {
            return {
              state: 'error',
              latency: _('Conflict'),
            };
          }
          if (s.configured) {
            return {
              state: 'warning',
              latency: _('Stopped'),
            };
          }
          return {
            state: 'error',
            latency: _('Not configured'),
          };
        }
        return {
          state: 'warning',
          latency: _('Unknown'),
        };
      }

      const selectedOutbound =
        section.outbounds.find((item) => item.selected) ?? section.outbounds[0];
      const targetCode =
        selectedOutbound?.urlTestInfo?.selectedCode ||
        selectedOutbound?.priorityInfo?.selectedCode ||
        selectedOutbound?.code ||
        section.code;
      const fallbackCode =
        selectedOutbound?.code && selectedOutbound.code !== targetCode
          ? selectedOutbound.code
          : section.code && section.code !== targetCode
            ? section.code
            : undefined;
      const { delay: liveDelay, reason } = await probeOutboundWithLiveRetry(
        targetCode,
        fallbackCode,
        section.latencyTestTimeout,
      );

      if (liveDelay !== null) {
        return {
          state: 'success',
          latency: `${liveDelay} ms`,
        };
      }

      if (section.action === 'vpn' && selectedOutbound?.runtimeAvailable) {
        return {
          state: 'warning',
          latency: `[${selectedOutbound.displayName || section.code}] ${_('Connectivity probe failed')}`,
        };
      }

      if (selectedOutbound?.latency && selectedOutbound.latency > 0) {
        return {
          state: 'success',
          latency: `${selectedOutbound.latency} ms`,
        };
      }

      return {
        state: 'error',
        latency: reason
          ? `${_('Not responding')}: ${reason}`
          : _('Not responding'),
      };
    }

    const { latency, state } = await getLatency();

    items.push({
      state,
      key: section.displayName,
      value: latency,
    });
  }

  const allGood = items.every((item) => item.state === 'success');

  const atLeastOneGood = items.some((item) => item.state !== 'error');

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items,
  });

  if (!atLeastOneGood) {
    throw new Error('Rule outbounds checks failed');
  }
}
