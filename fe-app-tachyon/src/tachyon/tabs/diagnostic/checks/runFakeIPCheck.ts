import { insertIf } from '../../../../helpers';
import { DIAGNOSTICS_CHECKS_MAP } from './constants';
import { TachyonShellMethods, RemoteFakeIPMethods } from '../../../methods';
import { getDashboardSections } from '../../../methods/custom/getDashboardSections';
import { store, type IDiagnosticsChecksItem } from '../../../services';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

const PROXY_ACTIONS = new Set([
  'connection',
  'proxy',
  'outbound',
  'vpn',
  'awg',
  'warp',
  'anytls',
  'snell',
  'mieru',
  'naive',
  'sudoku',
  'masque',
  'openvpn',
  'openconnect',
  'tewfai',
  'trusttunnel',
  'shadowtls',
]);

export async function runFakeIPCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.FAKEIP;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const routerFakeIPResponse = await TachyonShellMethods.checkFakeIP();
  const checkFakeIPResponse = await RemoteFakeIPMethods.getFakeIpCheck();
  const checkIPResponse = await RemoteFakeIPMethods.getIpCheck();
  const browserFakeIPCheckUnavailable = !checkFakeIPResponse.success;
  const browserFakeIPCheckMessage = checkFakeIPResponse.success
    ? ''
    : checkFakeIPResponse.message;

  let hasProxySection = true;
  try {
    const cachedSections = store.get().sectionsWidget?.data;
    const sections =
      cachedSections && cachedSections.length > 0
        ? cachedSections
        : (await getDashboardSections({ includeSubscriptionCopyState: false }))
            .data || [];
    if (sections.length > 0) {
      hasProxySection = sections.some(
        (s) => s.action && PROXY_ACTIONS.has(s.action),
      );
    }
  } catch (_e) {
    hasProxySection = true;
  }

  const checks = {
    routerFakeIP:
      routerFakeIPResponse.success && routerFakeIPResponse.data.fakeip,
    browserFakeIP:
      checkFakeIPResponse.success && checkFakeIPResponse.data.fakeip,
    canComparePublicIP:
      checkFakeIPResponse.success &&
      checkIPResponse.success &&
      Boolean(checkFakeIPResponse.data.IP && checkIPResponse.data.IP),
    differentIP:
      checkFakeIPResponse.success &&
      checkIPResponse.success &&
      Boolean(checkFakeIPResponse.data.IP && checkIPResponse.data.IP) &&
      checkFakeIPResponse.data.IP !== checkIPResponse.data.IP,
  };

  const selectiveTproxy = Boolean(
    (routerFakeIPResponse.success &&
      routerFakeIPResponse.data.selective_tproxy) ||
      (checkFakeIPResponse.success &&
        checkFakeIPResponse.data.selective_tproxy),
  );
  const fakeIPWorks = checks.routerFakeIP && checks.browserFakeIP;
  const isDirectOnly = fakeIPWorks && !hasProxySection && !checks.differentIP;
  const isSelectiveTproxyMatch =
    fakeIPWorks && selectiveTproxy && !checks.differentIP;
  const { state, description } = fakeIPWorks
    ? checks.differentIP || isDirectOnly || isSelectiveTproxyMatch
      ? { state: 'success' as const, description: _('Checks passed') }
      : {
          state: 'warning' as const,
          description: _('FakeIP works; public IP comparison is inconclusive'),
        }
    : browserFakeIPCheckUnavailable && checks.routerFakeIP
      ? {
          state: 'warning' as const,
          description: _('Browser FakeIP check could not be completed'),
        }
      : getMeta({
          allGood: false,
          atLeastOneGood: checks.routerFakeIP || checks.browserFakeIP,
        });

  const routerFakeIPValue = (() => {
    if (!routerFakeIPResponse.success) return '';
    const d = routerFakeIPResponse.data;
    const v4 = d.IPv4 || (d.IP && !d.IP.includes(':') ? d.IP : '');
    const v6 = d.IPv6 || (d.IP && d.IP.includes(':') ? d.IP : '');
    if (v4 && v6) return `IPv4: ${v4} · IPv6: ${v6}`;
    return v4 || v6 || d.IP || '';
  })();

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: checks.routerFakeIP ? 'success' : 'error',
        key: checks.routerFakeIP
          ? _('FakeIP DNS works')
          : _('FakeIP DNS does not work'),
        value: routerFakeIPValue,
      },
      {
        state: browserFakeIPCheckUnavailable
          ? 'warning'
          : checks.browserFakeIP
            ? 'success'
            : 'error',
        key: browserFakeIPCheckUnavailable
          ? _('Browser FakeIP check could not be completed')
          : checks.browserFakeIP
            ? _('Browser is using FakeIP correctly')
            : _('Browser is not using FakeIP'),
        value: browserFakeIPCheckMessage,
      },
      ...insertIf<IDiagnosticsChecksItem>(checks.browserFakeIP, [
        {
          state:
            checks.differentIP || isDirectOnly || isSelectiveTproxyMatch
              ? 'success'
              : 'warning',
          key: !checks.canComparePublicIP
            ? _('Could not compare FakeIP and control public IPs')
            : checks.differentIP
              ? _('FakeIP and control checks use different public IPs')
              : _('FakeIP and control checks use the same public IP'),
          value: isDirectOnly
            ? _('Direct connection via ISP')
            : isSelectiveTproxyMatch
              ? _('Selective TProxy: test domain uses direct path')
              : '',
        },
      ]),
    ],
  });
}
