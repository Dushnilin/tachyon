import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { PodkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { getDashboardSections } from '../../../methods/custom/getDashboardSections';
import { IDiagnosticsChecksItem } from '../../../services';

type SectionCheckState = IDiagnosticsChecksItem['state'];

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

        const isUrlTest = selectedOutbound?.type?.toLowerCase() === 'urltest';
        const latencyProxy = await PodkopShellMethods.getClashApiProxyLatency(
          selectedOutbound?.code ?? section.latencyTestCode ?? section.code,
          section.latencyTestTimeout,
        );
        const success = latencyProxy.success && !latencyProxy.data.message;

        if (isUrlTest) {
          const childOutbounds = section.outbounds.filter(
            (item) => item.code && item.type?.toLowerCase() !== 'urltest',
          );
          const childLatencyValues = childOutbounds
            .map((item) => Number(item.latency))
            .filter((latency) => Number.isFinite(latency) && latency > 0);
          const fastestDelay = childLatencyValues.length
            ? Math.min(...childLatencyValues)
            : latencyProxy.data.delay;
          const childLatencyText = childLatencyValues
            .map((latency) => `${latency}ms`)
            .join(' / ');

          if (success || childLatencyValues.length > 0) {
            const fastestText = fastestDelay
              ? `[${_('Fastest')}] ${fastestDelay} ms`
              : `[${_('Fastest')}] ${_('Not responding')}`;

            return {
              state: 'success',
              latency: childLatencyText
                ? `${fastestText} / ${childLatencyText}`
                : fastestText,
            };
          }

          return {
            state: 'error',
            latency: `[${_('Fastest')}] ${_('Not responding')}`,
          };
        }

        if (success) {
          return {
            state: 'success',
            latency: `[${selectedOutbound?.displayName ?? ''}] ${latencyProxy.data.delay}ms`,
          };
        }

        return {
          state: 'error',
          latency: `[${selectedOutbound?.displayName ?? ''}] ${_('Not responding')}`,
        };
      }

      const selectedOutbound = section.outbounds[0];
      const latencyProxy = await PodkopShellMethods.getClashApiProxyLatency(
        section.code,
        section.latencyTestTimeout,
      );

      const success = latencyProxy.success && !latencyProxy.data.message;

      if (success) {
        return {
          state: 'success',
          latency: `${latencyProxy.data.delay} ms`,
        };
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
