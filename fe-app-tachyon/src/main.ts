'use strict';
'require baseclass';
'require fs';
'require uci';
'require ui';
'require rpc';

if (typeof structuredClone !== 'function')
  globalThis.structuredClone = (obj) => JSON.parse(JSON.stringify(obj));

// Bridge LuCI lexical module variables onto globalThis so helper modules can access them reliably
const _g = globalThis as Record<string, unknown>;
if (typeof uci !== 'undefined' && !_g.uci) _g.uci = uci;
if (typeof ui !== 'undefined' && !_g.ui) _g.ui = ui;
if (typeof fs !== 'undefined' && !_g.fs) _g.fs = fs;
if (typeof rpc !== 'undefined' && !_g.rpc) _g.rpc = rpc;

export { validateIP } from './validators/validateIp';
export { validateDomain } from './validators/validateDomain';
export { validateDNS } from './validators/validateDns';
export { validateUrl } from './validators/validateUrl';
export { validatePath } from './validators/validatePath';
export { validateSubnet } from './validators/validateSubnet';
export { bulkValidate } from './validators/bulkValidate';
export { validateOutboundJson } from './validators/validateOutboundJson';
export { validateProxyUrl } from './validators/validateProxyUrl';
export { supportsVpnUrl } from './validators/validateVpnUrl';
export { parseValueList } from './helpers/parseValueList';
export { getProxyUrlName } from './helpers/getProxyUrlName';
export { formatOutboundType } from './helpers/formatOutboundType';
export { getProxyUrlTransport } from './helpers/getProxyUrlTransport';
export { injectGlobalStyles } from './helpers/injectGlobalStyles';
export { applyAutofillProtection } from './helpers/applyAutofillProtection';
export { showToast } from './helpers/showToast';
export { getClashUIUrl } from './helpers/getClashApiUrl';
export {
  attachCommunityListPicker,
  COMMUNITY_LIST_SUPERSETS,
  createInteractiveHintBanner,
  getSubsumedCommunityLists,
  parseCommunityHint,
} from './helpers/communityListPicker';
export { TachyonShellMethods } from './tachyon/methods/shell';
export { coreService } from './tachyon/services/core.service';
export { store } from './tachyon/services/store.service';
export { applyUiStateToStore } from './tachyon/services/uiState.service';
export { DashboardTab } from './tachyon/tabs/dashboard';
export {
  DASHBOARD_PRESETS,
  DASHBOARD_WIDGET_CATALOG,
  applyDashboardLayoutToDom,
  applyDashboardPreset,
  getDashboardLayoutConfig,
  openDashboardCustomizeModal,
  renderDashboardLayoutSettingsPanel,
  saveDashboardLayoutConfig,
} from './tachyon/tabs/dashboard/dashboardLayout';
export {
  navigateToServerInbound,
  openServerInfoModalForSection,
  registerServerSectionController,
  renderInboundServersDashboardWidget,
  renderServerTabInboundsOverview,
} from './tachyon/tabs/dashboard/inboundServers';
export { DiagnosticTab } from './tachyon/tabs/diagnostic';
export { MonitoringTab } from './tachyon/tabs/monitoring';
export { UpdatesTab } from './tachyon/tabs/updates';
export { renderDnsBenchmarkModal } from './tachyon/tabs/diagnostic/partials';
export {
  mountLanguageSelector,
  TACHYON_LANGUAGES,
} from './tachyon/languageSelector';
export {
  mountTachyonAppShell,
  refreshTachyonAppShell,
  getUiMode,
  setUiMode,
  getSidebarPos,
  setSidebarPos,
  getSidebarCollapsed,
  setSidebarCollapsed,
} from './tachyon/appShell';
export { openConnectionWizardModal } from './tachyon/connectionWizard';
export { mountTachyonStudioDeck } from './tachyon/studioDeck';
export {
  renderTachyonLogoSvg,
  renderTachyonDuckMascotSvg,
} from './icons/duckMascot';
export {
  BOOTSTRAP_DNS_SERVER_OPTIONS,
  DEFAULT_LATENCY_TEST_URL,
  DNS_SERVERS_BY_PROTOCOL,
  DOMAIN_LIST_HINTS,
  DOMAIN_LIST_OPTIONS,
  LATENCY_TEST_URL_OPTIONS,
  TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT,
  TACHYON_UCI_PACKAGE,
} from './constants';
