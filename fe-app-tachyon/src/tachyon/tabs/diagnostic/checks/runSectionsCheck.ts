import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { TachyonShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { getDashboardSections } from '../../../methods/custom/getDashboardSections';
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

        if (selectedOutbound?.code) {
          const latencyProxy =
            await TachyonShellMethods.getClashApiProxyLatency(
              selectedOutbound.code,
              section.latencyTestTimeout,
            );
          const proxySuccess =
            latencyProxy.success && !latencyProxy.data?.message;

          if (proxySuccess) {
            const delay = latencyProxy.data?.delay;
            if (typeof delay === 'number') {
              return {
                state: 'success',
                latency: `[${selectedOutbound.displayName ?? ''}] ${delay}ms`,
              };
            }

            const groupDelays = Object.values(latencyProxy.data || {}).filter(
              (v): v is number => typeof v === 'number' && v > 0,
            );
            if (groupDelays.length > 0) {
              const minDelay = Math.min(...groupDelays);
              return {
                state: 'success',
                latency: `[${selectedOutbound.displayName ?? ''}] ${minDelay}ms`,
              };
            }
          }

          return {
            state: 'error',
            latency: `[${selectedOutbound.displayName ?? ''}] ${_('Not responding')}`,
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

          return {
            state: 'error',
            latency: `[${selectedOutbound?.displayName ?? ''}] ${_('Not responding')}`,
          };
        }

        return {
          state: 'error',
          latency: _('Not responding'),
        };
      }

      // Service sections (zapret/zapret2/byedpi) don't have Clash API proxies.
      // Use the serviceStatus that was already fetched in getDashboardSections.
      const isService =
        ['zapret', 'zapret2', 'byedpi'].includes(section.action || '') ||
        Boolean(section.serviceStatus);

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

      const selectedOutbound = section.outbounds[0];
      const latencyProxy = await TachyonShellMethods.getClashApiProxyLatency(
        section.code,
        section.latencyTestTimeout,
      );

      const success = latencyProxy.success && !latencyProxy.data?.message;

      if (success) {
        const delay = latencyProxy.data?.delay;
        if (typeof delay === 'number') {
          return {
            state: 'success',
            latency: `${delay} ms`,
          };
        }

        const groupDelays = Object.values(latencyProxy.data || {}).filter(
          (v): v is number => typeof v === 'number' && v > 0,
        );
        if (groupDelays.length > 0) {
          return {
            state: 'success',
            latency: `${Math.min(...groupDelays)} ms`,
          };
        }
      }

      if (section.action === 'vpn' && selectedOutbound?.runtimeAvailable) {
        return {
          state: 'warning',
          latency: `[${selectedOutbound.displayName || section.code}] ${_('Connectivity probe failed')}`,
        };
      }

      return {
        state: 'error',
        latency: _('Not responding'),
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
