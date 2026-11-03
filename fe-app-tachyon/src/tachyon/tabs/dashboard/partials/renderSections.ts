import {
  renderLoaderCircleIcon24,
  renderCopyIcon24,
  renderLinkIcon24,
  renderInfoIcon24,
  renderZapIcon,
  renderAlertTriangleIcon,
  renderCheckIcon,
  renderGlobeIcon,
  renderPinIcon,
} from '../../../../icons';
import {
  isCopyableProxyLink,
  openPrefixColorPickerModal,
  renderOutboundTypeWithPopover,
  resolvePrefixBadgeStyle,
  svgEl,
} from '../../../../helpers';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import { showToast } from '../../../../helpers/showToast';
import { TachyonShellMethods } from '../../../methods/shell';
import { Tachyon } from '../../../types';
import { renderFlagEmojis } from './renderFlagEmojis';
import { formatServiceStatusMessage } from '../../../helpers/formatServiceStatusMessage';
import {
  groupOutboundsByCountry,
  detectOutboundCountry,
  ensureOutboundDisplayFlag,
  getCountryRegion,
  organizeCountryGroups,
  OutboundCountryGroup,
  WorldRegion,
} from '../../../helpers/country';

const gridHoveredSections = new Set<string>();
const gridFrozenOutboundOrders = new Map<string, string[]>();
const sectionTableSortState = new Map<
  string,
  { col: 'name' | 'source' | 'type' | 'latency'; dir: 'asc' | 'desc' }
>();

function getUciHandle(): typeof uci | undefined {
  return typeof uci !== 'undefined' ? uci : undefined;
}

function getUiHandle(): typeof ui | undefined {
  return typeof ui !== 'undefined' ? ui : undefined;
}

function getSectionServerDomainRulesRaw(sectionName: string): string[] {
  const uciRef = getUciHandle();
  if (!uciRef || typeof uciRef.get !== 'function' || !sectionName) return [];
  const raw = uciRef.get('tachyon', sectionName, 'server_domain_rules');
  if (Array.isArray(raw)) {
    return raw.map((v) => String(v || '').trim()).filter(Boolean);
  }
  if (typeof raw === 'string' && raw.trim()) {
    return [raw.trim()];
  }
  return [];
}

function matchesServerRuleKey(
  ruleKey: string,
  outbound: Tachyon.Outbound,
): boolean {
  const k = ruleKey.trim().toLowerCase();
  if (!k) return false;
  const code = String(outbound.code || '')
    .trim()
    .toLowerCase();
  const disp = String(outbound.displayName || '')
    .trim()
    .toLowerCase();
  const dispWithFlag = ensureOutboundDisplayFlag(outbound).trim().toLowerCase();
  const pfx = String(outbound.prefix || '')
    .trim()
    .toLowerCase();
  if (k === code) return true;
  if (pfx) {
    if (
      k === `${pfx}: ${disp}` ||
      k === `${pfx} ${disp}` ||
      k === `[${pfx}] ${disp}` ||
      k === `${pfx}: ${dispWithFlag}` ||
      k === `${pfx} ${dispWithFlag}` ||
      k === `[${pfx}] ${dispWithFlag}`
    ) {
      return true;
    }
    if (k.includes(': ') || k.startsWith('[')) {
      return false;
    }
  }
  return k === disp || k === dispWithFlag;
}

function getPinnedDomainsForOutbound(
  sectionName: string,
  outbound: Tachyon.Outbound,
): string[] {
  const entries = getSectionServerDomainRulesRaw(sectionName);
  const domains: string[] = [];
  for (const entry of entries) {
    const eqIdx = entry.indexOf('=');
    if (eqIdx <= 0) continue;
    const srvKey = entry.slice(0, eqIdx).trim();
    const domPart = entry.slice(eqIdx + 1).trim();
    if (!matchesServerRuleKey(srvKey, outbound)) continue;
    for (const token of domPart.split(/[\s,;]+/)) {
      const t = token.trim();
      if (t && !domains.includes(t)) {
        domains.push(t);
      }
    }
  }
  return domains;
}

function openPinSitesToServerModal(
  section: Tachyon.OutboundGroup,
  outbound: Tachyon.Outbound,
) {
  const uiRef = getUiHandle();
  const uciRef = getUciHandle();
  if (!uiRef || typeof uiRef.showModal !== 'function' || !uciRef) return;

  const isRu =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('ru');
  const t = (ru: string, en: string) => (isRu ? ru : en);

  const existingDomains = getPinnedDomainsForOutbound(
    section.sectionName,
    outbound,
  );
  const textareaEl = E(
    'textarea',
    {
      class: 'cbi-input-textarea',
      rows: 5,
      placeholder:
        '2ip.ru\nchatgpt.com\nnetflix.com\nspotify.com\ncommunity:openai',
      style:
        'width: 100%; font-family: monospace; font-size: 13px; padding: 8px 10px; border-radius: 8px; border: 1px solid rgba(148, 163, 184, 0.3); background: rgba(15, 23, 42, 0.35); color: inherit; box-sizing: border-box;',
    },
    existingDomains.join('\n'),
  ) as HTMLTextAreaElement;

  const quickServices = [
    { key: '2ip.ru', label: '2ip.ru' },
    { key: 'chatgpt.com', label: 'ChatGPT' },
    { key: 'claude.ai', label: 'Claude' },
    { key: 'gemini.google.com', label: 'Gemini' },
    { key: 'netflix.com', label: 'Netflix' },
    { key: 'spotify.com', label: 'Spotify' },
    { key: 'youtube.com', label: 'YouTube' },
    { key: 'instagram.com', label: 'Instagram' },
  ];

  const chipsWrap = E(
    'div',
    {
      style: 'display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px;',
    },
    quickServices.map((item) =>
      E(
        'button',
        {
          type: 'button',
          class: 'cbi-button',
          style:
            'padding: 2px 9px; font-size: 11px; border-radius: 999px; line-height: 1.5;',
          click: (ev: MouseEvent) => {
            ev.preventDefault();
            const current = textareaEl.value
              .split(/[\s,;]+/)
              .map((s) => s.trim())
              .filter(Boolean);
            if (!current.includes(item.key)) {
              current.push(item.key);
              textareaEl.value = current.join('\n');
            }
          },
        },
        `+ ${item.label}`,
      ),
    ),
  );

  const saveRule = async (domainsText: string) => {
    const tokens = domainsText
      .split(/[\s,;]+/)
      .map((s) => s.trim())
      .filter(Boolean);
    const uniqueTokens = Array.from(new Set(tokens));
    const allEntries = getSectionServerDomainRulesRaw(section.sectionName);
    const otherEntries = allEntries.filter((entry) => {
      const eqIdx = entry.indexOf('=');
      if (eqIdx <= 0) return true;
      const srvKey = entry.slice(0, eqIdx).trim();
      return !matchesServerRuleKey(srvKey, outbound);
    });

    if (uniqueTokens.length > 0) {
      otherEntries.push(`${outbound.code}=${uniqueTokens.join(', ')}`);
    }

    if (otherEntries.length > 0) {
      uciRef.set(
        'tachyon',
        section.sectionName,
        'server_domain_rules',
        otherEntries,
      );
    } else {
      uciRef.unset?.('tachyon', section.sectionName, 'server_domain_rules');
    }

    const condRefs = uciRef.get(
      'tachyon',
      section.sectionName,
      'condition_refs',
    );
    if (Array.isArray(condRefs) && condRefs.length === 1 && condRefs[0]) {
      if (otherEntries.length > 0) {
        uciRef.set('tachyon', condRefs[0], 'server_domain_rules', otherEntries);
      } else {
        uciRef.unset?.('tachyon', condRefs[0], 'server_domain_rules');
      }
    }

    await uciRef.save();
    uiRef.hideModal();
    showToast(
      uniqueTokens.length > 0
        ? t(
            `Привязано сайтов к серверу «${outbound.displayName}»: ${uniqueTokens.length}. Применяем маршрут...`,
            `Pinned ${uniqueTokens.length} site(s) to server "${outbound.displayName}". Applying route...`,
          )
        : t(
            `Привязка сайтов для сервера «${outbound.displayName}» очищена.`,
            `Cleared pinned sites for "${outbound.displayName}".`,
          ),
      'success',
    );
    TachyonShellMethods.serviceActionStart('reload').catch(() => {});
  };

  uiRef.showModal(
    t(
      `Привязка сайтов к серверу: ${outbound.displayName}`,
      `Pin Sites to Server: ${outbound.displayName}`,
    ),
    [
      E(
        'p',
        { style: 'margin: 0 0 10px 0; font-size: 13px; opacity: 0.85;' },
        t(
          'Укажите домены или сайты (по одному в строке или через запятую), которые всегда должны идти строго через этот сервер в обход общего балансировщика секции:',
          'Enter domains or sites (one per line or comma-separated) that should always route directly through this specific server, bypassing the section balancer:',
        ),
      ),
      textareaEl,
      chipsWrap,
      E(
        'div',
        {
          class: 'right',
          style:
            'margin-top: 14px; display: flex; justify-content: flex-end; gap: 8px;',
        },
        [
          ...(existingDomains.length > 0
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'btn cbi-button-reset',
                    click: () => saveRule(''),
                  },
                  t('Очистить привязку', 'Clear Pin'),
                ),
              ]
            : []),
          E(
            'button',
            {
              type: 'button',
              class: 'btn',
              click: () => uiRef.hideModal(),
            },
            t('Отмена', 'Cancel'),
          ),
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button-action important',
              click: () => saveRule(textareaEl.value),
            },
            t('Сохранить и применить', 'Save & Apply'),
          ),
        ],
      ),
    ],
  );
}

interface IRenderSectionsProps {
  loading: boolean;
  failed: boolean;
  section: Tachyon.OutboundGroup;
  isCollapsed?: boolean;
  onToggleCollapse?: () => void;
  collapsedSourceGroups?: Set<string>;
  onToggleSourceGroupCollapse?: (groupKey: string) => void;
  activeCountryFilter?: string;
  onFilterCountry?: (sectionName: string, countryCode?: string) => void;
  activeRegionFilter?: string;
  onFilterRegion?: (sectionName: string, region: string) => void;
  onTestLatency: (tag: string | string[]) => void;
  onChooseOutbound: (
    sectionName: string,
    selector: string,
    tag: string,
  ) => void;
  onCopyOutbound: (
    section: Tachyon.OutboundGroup,
    outbound: Tachyon.Outbound,
  ) => void;
  onShowUrlTestInfo: (
    section: Tachyon.OutboundGroup,
    outbound: Tachyon.Outbound,
  ) => void;
  onShowPriorityInfo: (
    section: Tachyon.OutboundGroup,
    outbound: Tachyon.Outbound,
  ) => void;
  onUpdateSubscription: (section: Tachyon.OutboundGroup) => void;
  latencyFetching: boolean;
  latencyProgress?: Tachyon.LatencyActionProgress;
  subscriptionUpdating: boolean;
  selectorSwitchingTag?: string;
  onTestSingleOutbound?: (sectionName: string, outboundCode: string) => void;
  testingOutboundCodes?: Record<string, boolean>;
  sectionStats?: {
    conns: number;
    download: number;
    upload: number;
    downSpeed: number;
    upSpeed: number;
  };
  hideSectionHeader?: boolean;
  nodesViewMode?: 'table' | 'tiles';
  onChangeNodesViewMode?: (mode: 'table' | 'tiles') => void;
}

const CONNECTION_ACTION_LABELS: Record<string, string> = {
  awg: 'AmneziaWG',
  warp: 'WARP',
  anytls: 'AnyTLS',
  snell: 'Snell',
  mieru: 'Mieru',
  naive: 'NaiveProxy',
  sudoku: 'Sudoku',
  masque: 'MASQUE',
  openvpn: 'OpenVPN',
  openconnect: 'OpenConnect',
  tewfai: 'TewFai',
  trusttunnel: 'TrustTunnel',
  shadowtls: 'ShadowTLS',
  desync: 'Native Desync',
  fptn: 'FPTN',
  vpn: 'VPN',
};

function renderFailedState() {
  return E(
    'div',
    {
      class: 'tachyon_dashboard-page__outbound-section centered',
      style: 'height: 127px',
    },
    E('span', {}, [E('span', {}, _('Dashboard currently unavailable'))]),
  );
}

function renderLoadingState() {
  return E('div', {
    id: 'dashboard-sections-grid-skeleton',
    class: 'tachyon_dashboard-page__outbound-section skeleton',
    style: 'height: 127px',
  });
}

function isValidHttpUrl(url?: string) {
  return Boolean(url && /^https?:\/\/\S+$/i.test(url));
}

function formatBytes(value?: number) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    return undefined;
  }

  return prettyBytes(value);
}

function formatDate(seconds?: number) {
  if (
    typeof seconds !== 'number' ||
    !Number.isFinite(seconds) ||
    seconds <= 0
  ) {
    return undefined;
  }

  const date = new Date(seconds * 1000);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }

  return date.toLocaleDateString(undefined, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
}

function renderMetadataAction(
  label: string,
  url?: string,
  shortLabel?: string,
) {
  if (!isValidHttpUrl(url)) {
    return undefined;
  }

  return E(
    'a',
    {
      class: 'btn tachyon_dashboard-page__subscription-meta__action',
      href: url,
      target: '_blank',
      rel: 'noopener noreferrer',
      title: label,
      'aria-label': label,
    },
    shortLabel
      ? [
          renderLinkIcon24(),
          E(
            'span',
            {
              class: 'tachyon_dashboard-page__subscription-meta__action-label',
            },
            shortLabel,
          ),
        ]
      : renderLinkIcon24(),
  );
}

function formatDateTime(seconds?: number) {
  if (
    typeof seconds !== 'number' ||
    !Number.isFinite(seconds) ||
    seconds <= 0
  ) {
    return undefined;
  }

  const date = new Date(seconds * 1000);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }

  return date.toLocaleString(undefined, {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function renderSubscriptionMetadata(
  metadata: Tachyon.SubscriptionMetadata | undefined,
  options?: {
    groupCount?: number;
    selectedOutbound?: Tachyon.Outbound;
    isGroupCollapsed?: boolean;
    onToggleGroup?: () => void;
    onUpdateSubscription?: () => void;
    subscriptionUpdating?: boolean;
  },
) {
  if (!metadata || Object.keys(metadata).length <= 1) {
    if (!options?.onToggleGroup && !options?.onUpdateSubscription) {
      return undefined;
    }
  }

  const title = metadata?.title || metadata?.fileName;
  const traffic = metadata?.traffic;
  const used = formatBytes(traffic?.used) || '0 B';
  const total = traffic?.isUnlimited
    ? '∞'
    : formatBytes(traffic?.total) || '0 B';
  const expire = formatDate(metadata?.expire);
  const refillDate = formatDate(metadata?.refillDate);
  const updatedAt = formatDateTime(metadata?.updatedAt);

  const isRu =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('ru');

  const rows = [
    traffic
      ? {
          kind: 'traffic' as const,
          label: _('Traffic'),
          value: `${used} / ${total}`,
          percent:
            !traffic.isUnlimited &&
            typeof traffic.used === 'number' &&
            typeof traffic.total === 'number' &&
            traffic.total > 0
              ? Math.min(100, Math.max(0, (traffic.used / traffic.total) * 100))
              : undefined,
        }
      : undefined,
    expire
      ? { kind: 'expire' as const, label: _('Expires'), value: expire }
      : undefined,
    refillDate
      ? { kind: 'refill' as const, label: _('Refill'), value: refillDate }
      : undefined,
    updatedAt
      ? {
          kind: 'updated' as const,
          label: isRu ? 'Обновлено' : _('Updated'),
          value: updatedAt,
        }
      : undefined,
  ].filter(Boolean) as {
    kind: 'traffic' | 'expire' | 'refill' | 'updated';
    label: string;
    value: string;
    percent?: number;
  }[];

  const updateBtn = options?.onUpdateSubscription
    ? E(
        'button',
        {
          type: 'button',
          class: 'btn tachyon_dashboard-page__subscription-meta__action',
          title: _('Update subscriptions'),
          'aria-label': _('Update subscriptions'),
          disabled: options.subscriptionUpdating ? true : undefined,
          click: (event: MouseEvent) => {
            event.preventDefault();
            event.stopPropagation();
            if (!options.subscriptionUpdating) {
              options.onUpdateSubscription?.();
            }
          },
        },
        options.subscriptionUpdating
          ? [
              renderLoaderCircleIcon24(),
              E(
                'span',
                {
                  class:
                    'tachyon_dashboard-page__subscription-meta__action-label',
                },
                isRu ? 'Обновление...' : _('Updating...'),
              ),
            ]
          : [
              svgEl(
                'svg',
                {
                  width: '14',
                  height: '14',
                  viewBox: '0 0 24 24',
                  fill: 'none',
                  stroke: 'currentColor',
                  'stroke-width': '2',
                  'stroke-linecap': 'round',
                  'stroke-linejoin': 'round',
                },
                [
                  svgEl('path', {
                    d: 'M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8',
                  }),
                  svgEl('polyline', { points: '21 3 21 8 16 8' }),
                ],
              ),
              E(
                'span',
                {
                  class:
                    'tachyon_dashboard-page__subscription-meta__action-label',
                },
                isRu ? 'Обновить' : _('Update'),
              ),
            ],
      )
    : undefined;

  const actions = [
    updateBtn,
    renderMetadataAction(
      _('Profile'),
      metadata?.webPageUrl,
      isRu ? 'Кабинет' : 'Profile',
    ),
    renderMetadataAction(
      _('Support'),
      metadata?.supportUrl,
      isRu ? 'Поддержка' : 'Support',
    ),
    renderMetadataAction(
      _('More details'),
      metadata?.announceUrl,
      isRu ? 'Инфо' : 'Info',
    ),
  ].filter(Boolean) as HTMLElement[];

  const isToggleable = Boolean(options?.onToggleGroup);
  const isGroupCollapsed = Boolean(options?.isGroupCollapsed);

  return E(
    'div',
    {
      class: [
        'tachyon_dashboard-page__subscription-meta',
        isToggleable
          ? 'tachyon_dashboard-page__subscription-meta--collapsible'
          : '',
        isGroupCollapsed
          ? 'tachyon_dashboard-page__subscription-meta--collapsed'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
      click: isToggleable
        ? (event: MouseEvent) => {
            if (
              event.target &&
              (event.target as Element).closest('a, button')
            ) {
              return;
            }
            options?.onToggleGroup?.();
          }
        : undefined,
    },
    [
      E('div', { class: 'tachyon_dashboard-page__subscription-meta__main' }, [
        E(
          'div',
          { class: 'tachyon_dashboard-page__subscription-meta__header-row' },
          [
            E(
              'div',
              {
                class: 'tachyon_dashboard-page__subscription-meta__title-group',
              },
              [
                ...(isToggleable
                  ? [
                      svgEl(
                        'svg',
                        {
                          width: '15',
                          height: '15',
                          viewBox: '0 0 24 24',
                          fill: 'none',
                          stroke: 'currentColor',
                          'stroke-width': '2',
                          'stroke-linecap': 'round',
                          'stroke-linejoin': 'round',
                          style: `flex-shrink: 0; transition: transform 0.2s; transform: rotate(${isGroupCollapsed ? '-90deg' : '0deg'})`,
                        },
                        [svgEl('polyline', { points: '6 9 12 15 18 9' })],
                      ),
                    ]
                  : []),
                title
                  ? E(
                      'div',
                      {
                        class:
                          'tachyon_dashboard-page__subscription-meta__title',
                      },
                      renderFlagEmojis(title),
                    )
                  : E(
                      'div',
                      {
                        class:
                          'tachyon_dashboard-page__subscription-meta__heading',
                      },
                      _('Subscription'),
                    ),
                typeof options?.groupCount === 'number'
                  ? E(
                      'span',
                      {
                        class: 'tachyon_dashboard-page__source-group__count',
                      },
                      `${options.groupCount}`,
                    )
                  : '',
                isGroupCollapsed && options?.selectedOutbound
                  ? E(
                      'span',
                      {
                        class:
                          'tachyon_dashboard-page__source-group__active-badge',
                      },
                      `● ${options.selectedOutbound.displayName}`,
                    )
                  : '',
              ],
            ),
            rows.length
              ? E(
                  'div',
                  { class: 'tachyon_dashboard-page__subscription-meta__facts' },
                  rows.map((row) =>
                    E(
                      'div',
                      {
                        class: `tachyon_dashboard-page__subscription-meta__fact tachyon_dashboard-page__subscription-meta__fact--${row.kind}`,
                      },
                      [
                        E(
                          'div',
                          {
                            class:
                              'tachyon_dashboard-page__subscription-meta__fact-top',
                          },
                          [
                            E(
                              'span',
                              {
                                class:
                                  'tachyon_dashboard-page__subscription-meta__fact-key',
                              },
                              row.label,
                            ),
                            E(
                              'span',
                              {
                                class:
                                  'tachyon_dashboard-page__subscription-meta__fact-value',
                              },
                              row.value,
                            ),
                          ],
                        ),
                        ...(typeof row.percent === 'number'
                          ? [
                              E(
                                'div',
                                {
                                  class:
                                    'tachyon_dashboard-page__subscription-meta__progress',
                                },
                                [
                                  E('div', {
                                    class:
                                      'tachyon_dashboard-page__subscription-meta__progress-bar',
                                    style: `width: ${row.percent.toFixed(1)}%;`,
                                  }),
                                ],
                              ),
                            ]
                          : []),
                      ],
                    ),
                  ),
                )
              : '',
            actions.length
              ? E(
                  'div',
                  {
                    class: 'tachyon_dashboard-page__subscription-meta__actions',
                  },
                  actions,
                )
              : '',
          ],
        ),
      ]),
      !isGroupCollapsed && metadata?.announce
        ? E(
            'blockquote',
            { class: 'tachyon_dashboard-page__subscription-meta__announce' },
            metadata.announce,
          )
        : '',
    ],
  );
}

function renderSubscriptionUpdateAction(
  section: Tachyon.OutboundGroup,
  subscriptionUpdating: boolean,
  onUpdateSubscription: (section: Tachyon.OutboundGroup) => void,
) {
  if (!section.subscriptionSourceCount) {
    return undefined;
  }

  return E(
    'button',
    {
      type: 'button',
      class:
        'btn tachyon_dashboard-page__outbound-section__subscription-update',
      'aria-label': _('Update subscriptions'),
      disabled: subscriptionUpdating ? true : undefined,
      click: (event: MouseEvent) => {
        event.preventDefault();
        event.stopPropagation();
        if (subscriptionUpdating) {
          return;
        }

        onUpdateSubscription(section);
      },
    },
    subscriptionUpdating
      ? [renderLoaderCircleIcon24(), _('Update subscriptions')]
      : _('Update subscriptions'),
  );
}

export function getLatencyTestLabel(
  latencyProgress?: Tachyon.LatencyActionProgress,
) {
  const total = Math.trunc(Number(latencyProgress?.total ?? 0));
  if (!Number.isFinite(total) || total <= 0) {
    return _('Test latency');
  }

  const completedValue = Number(latencyProgress?.completed ?? 0);
  const completed = Number.isFinite(completedValue)
    ? Math.trunc(completedValue)
    : 0;

  return `${_('Test latency')}: ${Math.min(
    Math.max(0, completed),
    total,
  )}/${total}`;
}

function renderCountryChips(
  countryGroups: OutboundCountryGroup[],
  totalCount: number,
  activeFilter?: string,
  onFilter?: (sectionName: string, countryCode?: string) => void,
  sectionName?: string,
  options?: {
    chipsGrouping?: 'regions' | 'smart_top' | 'latency' | 'alphabetical';
    activeRegion?: string;
    onFilterRegion?: (sectionName: string, region: string) => void;
    activeCountryCode?: string;
    isExpanded?: boolean;
    onToggleExpand?: () => void;
  },
): HTMLElement {
  const isRu =
    (typeof document !== 'undefined' &&
      (document.documentElement?.lang || '').toLowerCase().startsWith('ru')) ||
    false;

  const mode = options?.chipsGrouping || 'regions';
  const activeRegion = (options?.activeRegion as WorldRegion) || 'all';
  const isExpanded = Boolean(options?.isExpanded);

  const organized = organizeCountryGroups(countryGroups, mode, {
    activeCountryCode: options?.activeCountryCode,
    selectedRegion: activeRegion,
  });

  const filterTitle = isRu
    ? 'Фильтр по странам'
    : typeof _ === 'function'
      ? _('Country filter')
      : 'Country filter';

  const activeCountryGroup =
    activeFilter && activeFilter !== 'ALL'
      ? countryGroups.find((g) => g.countryCode === activeFilter)
      : undefined;
  const activeRegionMeta =
    mode === 'regions' && activeRegion !== 'all'
      ? organized.availableRegions.find((r) => r.id === activeRegion)
      : undefined;

  const activeFilterSummary = activeCountryGroup
    ? `${activeCountryGroup.countryFlag ? `${activeCountryGroup.countryFlag} ` : ''}${activeCountryGroup.countryName || activeCountryGroup.countryCode}`
    : activeRegionMeta
      ? `${activeRegionMeta.flag ? `${activeRegionMeta.flag} ` : ''}${activeRegionMeta.label}`
      : '';

  const container = E('div', {
    class: [
      'tachyon_dashboard-page__country-chips-container',
      !isExpanded
        ? 'tachyon_dashboard-page__country-chips-container--collapsed'
        : '',
    ]
      .filter(Boolean)
      .join(' '),
  });

  const headerBar = E(
    'div',
    {
      class: 'tachyon_dashboard-page__country-chips__header',
      click: (e: MouseEvent) => {
        e.preventDefault();
        e.stopPropagation();
        options?.onToggleExpand?.();
      },
    },
    [
      svgEl(
        'svg',
        {
          width: '14',
          height: '14',
          viewBox: '0 0 24 24',
          fill: 'none',
          stroke: 'currentColor',
          'stroke-width': '2',
          'stroke-linecap': 'round',
          'stroke-linejoin': 'round',
          style: `flex-shrink: 0; transition: transform 0.2s; transform: rotate(${isExpanded ? '0deg' : '-90deg'})`,
        },
        [svgEl('polyline', { points: '6 9 12 15 18 9' })],
      ),
      E('span', {}, filterTitle),
      E(
        'span',
        { class: 'tachyon_dashboard-page__auto-groups__count' },
        `${countryGroups.length}`,
      ),
      activeFilterSummary
        ? E(
            'span',
            {
              class: 'tachyon_dashboard-page__source-group__active-badge',
              style: 'text-transform: none; letter-spacing: normal;',
            },
            renderFlagEmojis(activeFilterSummary),
          )
        : '',
    ],
  );
  container.appendChild(headerBar);

  const bodyContainer = E('div', {
    class: 'tachyon_dashboard-page__country-chips-body',
  });

  // 1. Region Tabs Bar (if mode === 'regions' and there are multiple regions)
  if (mode === 'regions' && organized.availableRegions.length > 2) {
    const regionTabs = organized.availableRegions.map((reg) => {
      const isRegActive = activeRegion === reg.id;
      return E(
        'button',
        {
          type: 'button',
          class: `tachyon_dashboard-page__region-tab${isRegActive ? ' tachyon_dashboard-page__region-tab--active' : ''}`,
          title: `${reg.label} (${reg.count})`,
          click: (e: MouseEvent) => {
            e.preventDefault();
            e.stopPropagation();
            if (options?.onFilterRegion && sectionName) {
              options.onFilterRegion(sectionName, reg.id);
            }
          },
        },
        [
          E(
            'span',
            {
              class: 'tachyon_dashboard-page__flag-emoji',
              style: reg.flag
                ? undefined
                : 'display: inline-flex; align-items: center;',
            },
            reg.flag || [renderGlobeIcon(12)],
          ),
          E(
            'span',
            { class: 'tachyon_dashboard-page__region-tab__name' },
            reg.label,
          ),
          E(
            'span',
            { class: 'tachyon_dashboard-page__country-chip__count' },
            `${reg.count}`,
          ),
        ],
      );
    });

    const regionBar = E(
      'div',
      { class: 'tachyon_dashboard-page__region-bar' },
      regionTabs,
    );
    bodyContainer.appendChild(regionBar);
  }

  // 3. Country Chips Row
  const isAllActive = !activeFilter || activeFilter === 'ALL';
  const allLabel = isRu ? 'Все' : typeof _ === 'function' ? _('All') : 'All';

  const currentRegionMeta = organized.availableRegions.find(
    (r) => r.id === activeRegion,
  );
  const allChipCount =
    mode === 'regions' && activeRegion !== 'all' && currentRegionMeta
      ? currentRegionMeta.count
      : totalCount;

  const allBtn = E(
    'button',
    {
      type: 'button',
      class: `tachyon_dashboard-page__country-chip${isAllActive ? ' tachyon_dashboard-page__country-chip--active' : ''}`,
      click: (e: MouseEvent) => {
        e.preventDefault();
        e.stopPropagation();
        if (sectionName && onFilter) {
          onFilter(sectionName, undefined);
        }
      },
    },
    [
      E(
        'span',
        {
          class:
            'tachyon_dashboard-page__country-chip__flag tachyon_dashboard-page__flag-emoji',
          style: 'display: inline-flex; align-items: center;',
        },
        [renderGlobeIcon(12)],
      ),
      E(
        'span',
        { class: 'tachyon_dashboard-page__country-chip__name' },
        allLabel,
      ),
      E(
        'span',
        { class: 'tachyon_dashboard-page__country-chip__count' },
        `${allChipCount}`,
      ),
    ],
  );

  const chipElements: HTMLElement[] = [allBtn];

  const renderSingleChip = (group: OutboundCountryGroup) => {
    const isActive = activeFilter === group.countryCode;
    const minLat =
      group.bestLatency > 0 && Number.isFinite(group.bestLatency)
        ? `${group.bestLatency}ms`
        : '';

    let latClass = '';
    if (group.bestLatency > 0 && Number.isFinite(group.bestLatency)) {
      if (group.bestLatency < 100) {
        latClass = 'tachyon_dashboard-page__country-chip__latency--fast';
      } else if (group.bestLatency <= 300) {
        latClass = 'tachyon_dashboard-page__country-chip__latency--medium';
      } else {
        latClass = 'tachyon_dashboard-page__country-chip__latency--slow';
      }
    }

    const displayName = group.countryName || group.countryCode;

    return E(
      'button',
      {
        type: 'button',
        class: `tachyon_dashboard-page__country-chip${isActive ? ' tachyon_dashboard-page__country-chip--active' : ''}`,
        title: `${displayName} (${group.outbounds.length})`,
        click: (e: MouseEvent) => {
          e.preventDefault();
          e.stopPropagation();
          if (sectionName && onFilter) {
            onFilter(sectionName, isActive ? undefined : group.countryCode);
          }
        },
      },
      [
        E(
          'span',
          {
            class:
              'tachyon_dashboard-page__country-chip__flag tachyon_dashboard-page__flag-emoji',
            style: group.countryFlag
              ? undefined
              : 'display: inline-flex; align-items: center;',
          },
          group.countryFlag || [renderGlobeIcon(12)],
        ),
        E(
          'span',
          { class: 'tachyon_dashboard-page__country-chip__name' },
          displayName,
        ),
        E(
          'span',
          { class: 'tachyon_dashboard-page__country-chip__count' },
          `${group.outbounds.length}`,
        ),
        minLat
          ? E(
              'span',
              {
                class: `tachyon_dashboard-page__country-chip__latency ${latClass}`,
              },
              minLat,
            )
          : '',
      ],
    );
  };

  if (mode === 'smart_top' && organized.topCount && organized.topCount > 0) {
    const topGroups = organized.groups.slice(0, organized.topCount);
    const restGroups = organized.groups.slice(organized.topCount);

    for (const g of topGroups) {
      chipElements.push(renderSingleChip(g));
    }

    if (restGroups.length > 0) {
      chipElements.push(
        E('div', {
          class: 'tachyon_dashboard-page__country-chip-divider',
          title: isRu ? 'Остальные страны (А–Я)' : 'Other countries (A–Z)',
        }),
      );
      for (const g of restGroups) {
        chipElements.push(renderSingleChip(g));
      }
    }
  } else {
    for (const g of organized.groups) {
      chipElements.push(renderSingleChip(g));
    }
  }

  const chipsBar = E(
    'div',
    {
      class: 'tachyon_dashboard-page__country-chips',
    },
    chipElements,
  );

  bodyContainer.appendChild(chipsBar);
  container.appendChild(bodyContainer);
  return container;
}

function renderCountryAccordionHeader(
  group: OutboundCountryGroup,
  isCollapsed: boolean,
  onToggle?: () => void,
): HTMLElement {
  const selectedMember = group.outbounds.find((m) => m.selected);
  const minLat =
    group.bestLatency > 0 && Number.isFinite(group.bestLatency)
      ? `${group.bestLatency}ms`
      : '';

  return E(
    'div',
    {
      class: [
        'tachyon_dashboard-page__subscription-meta',
        'tachyon_dashboard-page__subscription-meta--collapsible',
        'tachyon_dashboard-page__country-meta',
        isCollapsed
          ? 'tachyon_dashboard-page__subscription-meta--collapsed'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
      click: onToggle,
    },
    [
      E('div', { class: 'tachyon_dashboard-page__subscription-meta__main' }, [
        svgEl(
          'svg',
          {
            width: '15',
            height: '15',
            viewBox: '0 0 24 24',
            fill: 'none',
            stroke: 'currentColor',
            'stroke-width': '2',
            'stroke-linecap': 'round',
            'stroke-linejoin': 'round',
            style: `flex-shrink: 0; transition: transform 0.2s; transform: rotate(${isCollapsed ? '-90deg' : '0deg'})`,
          },
          [svgEl('polyline', { points: '6 9 12 15 18 9' })],
        ),
        E(
          'span',
          {
            class:
              'tachyon_dashboard-page__country-chip__flag tachyon_dashboard-page__flag-emoji',
            style: 'font-size: 16px;',
          },
          group.countryFlag,
        ),
        E(
          'div',
          { class: 'tachyon_dashboard-page__subscription-meta__heading' },
          group.countryName,
        ),
        E(
          'span',
          { class: 'tachyon_dashboard-page__source-group__count' },
          `${group.outbounds.length}`,
        ),
        isCollapsed && selectedMember
          ? E(
              'span',
              {
                class: 'tachyon_dashboard-page__source-group__active-badge',
              },
              `● ${selectedMember.displayName}`,
            )
          : '',
      ]),
      minLat
        ? E(
            'div',
            { style: 'font-size: 12px; opacity: 0.7;' },
            `${
              typeof document !== 'undefined' &&
              (document.documentElement?.lang || '')
                .toLowerCase()
                .startsWith('ru')
                ? 'Мин. задержка'
                : typeof _ === 'function'
                  ? _('Min latency')
                  : 'Min latency'
            }: ${minLat}`,
          )
        : '',
    ],
  );
}

function renderAutoGroupsBlock(
  topGroups: Tachyon.Outbound[],
  renderOutbound: (ob: Tachyon.Outbound) => HTMLElement,
  options?: {
    isCollapsed?: boolean;
    onToggleCollapse?: () => void;
  },
): HTMLElement | null {
  if (topGroups.length === 0) return null;

  const isCollapsed = Boolean(options?.isCollapsed);
  const isRu =
    (typeof document !== 'undefined' &&
      (document.documentElement?.lang || '').toLowerCase().startsWith('ru')) ||
    false;
  const title = isRu
    ? 'Режимы автовыбора'
    : typeof _ === 'function'
      ? _('Auto selection modes')
      : 'Auto selection modes';

  const selectedGroup = topGroups.find((g) => g.selected);
  const rawSubName =
    selectedGroup?.urlTestInfo?.selectedName ||
    selectedGroup?.priorityInfo?.selectedName ||
    selectedGroup?.urlTestInfo?.outbounds?.find(
      (m) =>
        m.selected ||
        (selectedGroup.urlTestInfo?.selectedCode &&
          m.code === selectedGroup.urlTestInfo.selectedCode),
    )?.displayName ||
    selectedGroup?.priorityInfo?.outbounds?.find(
      (m) =>
        m.selected ||
        (selectedGroup.priorityInfo?.selectedCode &&
          m.code === selectedGroup.priorityInfo.selectedCode),
    )?.displayName ||
    '';
  const activeSubName = rawSubName
    ? ensureOutboundDisplayFlag({ displayName: rawSubName })
    : '';

  let latencyValue = selectedGroup?.latency;
  if (!latencyValue || latencyValue <= 0) {
    const info = selectedGroup?.urlTestInfo || selectedGroup?.priorityInfo;
    const member = info?.outbounds?.find(
      (m) =>
        m.selected ||
        (info.selectedCode && m.code === info.selectedCode) ||
        (rawSubName && m.displayName === rawSubName),
    );
    if (member && member.latency) {
      latencyValue = member.latency;
    }
  }

  function getAutoGroupLatencyColor() {
    if (!latencyValue) return 'inherit';
    if (latencyValue === -1 || latencyValue < 0)
      return 'var(--error-color-medium, red)';
    if (latencyValue < 800) return 'var(--success-color-medium, green)';
    if (latencyValue < 1500) return 'var(--warn-color-medium, orange)';
    return 'var(--error-color-medium, red)';
  }

  let autoGroupLatencyText = '';
  if (latencyValue !== undefined && latencyValue > 0) {
    autoGroupLatencyText = `${latencyValue}ms`;
  } else if (
    latencyValue !== undefined &&
    (latencyValue === -1 || latencyValue < 0)
  ) {
    autoGroupLatencyText =
      typeof _ === 'function' ? _('Not responding') : 'Not responding';
  }

  const collapsedBadgeText = selectedGroup
    ? `● ${selectedGroup.displayName}${activeSubName ? ` → ${activeSubName}` : ''}`
    : '';

  return E(
    'div',
    {
      class: [
        'tachyon_dashboard-page__auto-groups',
        isCollapsed ? 'tachyon_dashboard-page__auto-groups--collapsed' : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    [
      E(
        'div',
        {
          class: 'tachyon_dashboard-page__auto-groups__header',
          click: (e: MouseEvent) => {
            e.preventDefault();
            e.stopPropagation();
            options?.onToggleCollapse?.();
          },
        },
        [
          svgEl(
            'svg',
            {
              width: '14',
              height: '14',
              viewBox: '0 0 24 24',
              fill: 'none',
              stroke: 'currentColor',
              'stroke-width': '2',
              'stroke-linecap': 'round',
              'stroke-linejoin': 'round',
              style: `flex-shrink: 0; transition: transform 0.2s; transform: rotate(${isCollapsed ? '-90deg' : '0deg'})`,
            },
            [svgEl('polyline', { points: '6 9 12 15 18 9' })],
          ),
          E('span', {}, title),
          E(
            'span',
            { class: 'tachyon_dashboard-page__auto-groups__count' },
            `${topGroups.length}`,
          ),
          isCollapsed && collapsedBadgeText
            ? E(
                'span',
                {
                  class: 'tachyon_dashboard-page__source-group__active-badge',
                  style:
                    'text-transform: none; letter-spacing: normal; max-width: min(380px, 50vw);',
                  title: `${collapsedBadgeText.replace(/^●\s*/, '')}${autoGroupLatencyText ? ` • ${autoGroupLatencyText}` : ''}`,
                },
                [
                  ...renderFlagEmojis(collapsedBadgeText),
                  autoGroupLatencyText
                    ? E(
                        'span',
                        {
                          style: `color: ${getAutoGroupLatencyColor()}; margin-left: 4px; font-weight: 600;`,
                        },
                        `• ${autoGroupLatencyText}`,
                      )
                    : '',
                ],
              )
            : '',
        ],
      ),
      E(
        'div',
        { class: 'tachyon_dashboard-page__auto-groups-grid' },
        topGroups.map((ob) => renderOutbound(ob)),
      ),
    ],
  );
}

function renderDefaultState({
  section,
  onChooseOutbound,
  onCopyOutbound,
  onShowUrlTestInfo,
  onShowPriorityInfo,
  onTestLatency,
  onUpdateSubscription,
  latencyFetching,
  latencyProgress,
  subscriptionUpdating,
  selectorSwitchingTag,
  onTestSingleOutbound,
  testingOutboundCodes,
  isCollapsed,
  onToggleCollapse,
  collapsedSourceGroups,
  onToggleSourceGroupCollapse,
  activeCountryFilter,
  onFilterCountry,
  activeRegionFilter,
  onFilterRegion,
  sectionStats,
  hideSectionHeader,
  nodesViewMode,
}: IRenderSectionsProps) {
  const isConnectionNode =
    !section.withTagSelect &&
    [
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
    ].includes(section.action || '');
  const isServiceNode =
    ['zapret', 'zapret2', 'byedpi', 'desync', 'wdtt', 'olcrtc'].includes(
      section.action || '',
    ) || Boolean(section.serviceStatus);

  if (isServiceNode) {
    const ss = section.serviceStatus;
    const serviceType =
      ss?.serviceType ||
      (['zapret', 'zapret2', 'byedpi', 'desync', 'wdtt', 'olcrtc'].includes(
        section.action || '',
      )
        ? (section.action as Tachyon.ServiceStatus['serviceType'])
        : 'zapret');
    const typeLabel =
      serviceType === 'zapret'
        ? 'Zapret'
        : serviceType === 'zapret2'
          ? 'Zapret2'
          : serviceType === 'byedpi'
            ? 'ByeDPI'
            : serviceType === 'wdtt'
              ? 'WDTT'
              : serviceType === 'olcrtc'
                ? 'OlcRTC'
                : serviceType === 'desync'
                  ? _('Native Desync')
                  : 'FPTN';
    const statusColor = ss
      ? ss.ready
        ? 'var(--success-color-medium, green)'
        : ss.conflict
          ? 'var(--error-color-medium, red)'
          : ss.configured
            ? 'var(--warn-color-medium, orange)'
            : 'var(--primary-color-low, lightgray)'
      : 'var(--primary-color-low, lightgray)';
    const statusText = ss
      ? ss.ready
        ? _('Running')
        : ss.conflict
          ? _('Conflict')
          : ss.configured
            ? _('Stopped')
            : _('Not configured')
      : _('Unknown');

    return E(
      'div',
      {
        class: [
          'tachyon_dashboard-page__outbound-section',
          section.configError
            ? 'tachyon_dashboard-page__outbound-section--error'
            : '',
        ]
          .filter(Boolean)
          .join(' '),
      },
      [
        ...(hideSectionHeader
          ? []
          : [
              E(
                'div',
                {
                  class:
                    'tachyon_dashboard-page__outbound-section__title-section',
                  style: 'cursor: default;',
                },
                [
                  E(
                    'div',
                    {
                      class:
                        'tachyon_dashboard-page__outbound-section__title-section__title',
                      style: 'display: flex; align-items: center; gap: 8px;',
                    },
                    [
                      E('span', {}, section.displayName),
                      renderConfigErrorBadge(section),
                      E(
                        'span',
                        {
                          style:
                            'font-size: 12px; opacity: 0.6; font-weight: normal;',
                        },
                        typeLabel,
                      ),
                    ],
                  ),
                ],
              ),
            ]),
        renderConfigErrorBanner(section),
        E(
          'div',
          {
            style:
              'display: flex; flex-wrap: wrap; gap: 16px; padding: 8px 16px 12px;',
          },
          [
            E(
              'div',
              { style: 'display: flex; align-items: center; gap: 6px;' },
              [
                E(
                  'span',
                  { style: 'opacity: 0.7; font-size: 13px;' },
                  _('Status') + ':',
                ),
                E(
                  'span',
                  {
                    style: `font-size: 13px; font-weight: 500; color: ${statusColor};`,
                  },
                  statusText,
                ),
              ],
            ),
            ss && ss.restartCount > 0
              ? E(
                  'div',
                  { style: 'display: flex; align-items: center; gap: 6px;' },
                  [
                    E(
                      'span',
                      { style: 'opacity: 0.7; font-size: 13px;' },
                      _('Restarts') + ':',
                    ),
                    E(
                      'span',
                      {
                        style:
                          'font-size: 13px; font-weight: 500; color: var(--warn-color-medium, orange);',
                      },
                      `${ss.restartCount}`,
                    ),
                  ],
                )
              : '',
            ss && ss.unstable
              ? E(
                  'div',
                  { style: 'display: flex; align-items: center; gap: 6px;' },
                  [
                    E(
                      'span',
                      {
                        style:
                          'font-size: 13px; font-weight: 500; color: var(--error-color-medium, red);',
                      },
                      _('Unstable'),
                    ),
                  ],
                )
              : '',
          ],
        ),
        ss?.statusMessage
          ? E(
              'div',
              {
                style:
                  'padding: 0 16px 8px; font-size: 12px; opacity: 0.6; word-break: break-word;',
              },
              formatServiceStatusMessage(ss.statusMessage),
            )
          : '',
      ],
    );
  }

  function testLatency() {
    if (section.withTagSelect) {
      return onTestLatency(
        section.latencyTestCodes?.length
          ? section.latencyTestCodes
          : section.latencyTestCode || section.code,
      );
    }

    if (section.outbounds.length) {
      return onTestLatency(section.outbounds[0].code);
    }
  }

  function renderOutbound(outbound: Tachyon.Outbound) {
    const isTestingSingle = Boolean(
      testingOutboundCodes && testingOutboundCodes[outbound.code],
    );

    function getLatencyClass() {
      if (isConnectionNode) {
        if (latencyFetching) {
          return 'tachyon_dashboard-page__outbound-grid__item__latency--yellow';
        }
        if (outbound.latency === -1 || !outbound.runtimeAvailable) {
          return 'tachyon_dashboard-page__outbound-grid__item__latency--red';
        }
        if (!outbound.latency) {
          return 'tachyon_dashboard-page__outbound-grid__item__latency--green';
        }
        // Fall through to normal latency color if we have a ping
      }

      if (!outbound.latency) {
        // Service nodes (desync, zapret2, …) have no measurable latency;
        // colour the badge green when bypass is active, red when stopped.
        if (isServiceNode) {
          return section.serviceStatus?.ready
            ? 'tachyon_dashboard-page__outbound-grid__item__latency--green'
            : 'tachyon_dashboard-page__outbound-grid__item__latency--red';
        }
        return 'tachyon_dashboard-page__outbound-grid__item__latency--empty';
      }

      if (outbound.latency === -1 || outbound.latency < 0) {
        return 'tachyon_dashboard-page__outbound-grid__item__latency--red';
      }

      if (outbound.latency < 800) {
        return 'tachyon_dashboard-page__outbound-grid__item__latency--green';
      }

      if (outbound.latency < 1500) {
        return 'tachyon_dashboard-page__outbound-grid__item__latency--yellow';
      }

      return 'tachyon_dashboard-page__outbound-grid__item__latency--red';
    }

    const connectionStatusText = latencyFetching
      ? `● ${_('Checking...')}`
      : outbound.latency && outbound.latency > 0
        ? `● ${outbound.latency} ms`
        : outbound.latency === -1
          ? `● ${_('Not responding')}`
          : outbound.runtimeAvailable
            ? `● ${_('Connected')}`
            : `● ${_('Not connected')}`;

    const canCopyLink =
      Boolean(outbound.canCopyLink) || isCopyableProxyLink(outbound.link);
    const selectorSwitching = Boolean(selectorSwitchingTag);
    const outboundSwitching = selectorSwitchingTag === outbound.code;
    const canChooseOutbound =
      section.withTagSelect &&
      outbound.runtimeAvailable !== false &&
      !selectorSwitching &&
      !outbound.selected;
    const isAutoGroup = Boolean(outbound.urlTestInfo || outbound.priorityInfo);
    const className = [
      'tachyon_dashboard-page__outbound-grid__item',
      isAutoGroup
        ? 'tachyon_dashboard-page__outbound-grid__item--auto-group'
        : '',
      outbound.selected
        ? 'tachyon_dashboard-page__outbound-grid__item--active'
        : '',
      canChooseOutbound
        ? 'tachyon_dashboard-page__outbound-grid__item--selectable'
        : '',
      section.withTagSelect && !canChooseOutbound
        ? 'tachyon_dashboard-page__outbound-grid__item--disabled'
        : '',
      outboundSwitching
        ? 'tachyon_dashboard-page__outbound-grid__item--switching'
        : '',
    ]
      .filter(Boolean)
      .join(' ');

    if (isConnectionNode) {
      const isAlive = Boolean(
        outbound.runtimeAvailable || (outbound.latency && outbound.latency > 0),
      );
      const statusText = latencyFetching
        ? _('Checking...')
        : outbound.latency === -1 || outbound.latency < 0
          ? _('Not responding')
          : isAlive
            ? _('Connected')
            : _('Not connected');

      const statusColor = latencyFetching
        ? 'var(--warn-color-medium, orange)'
        : outbound.latency === -1 || outbound.latency < 0
          ? 'var(--error-color-medium, red)'
          : isAlive
            ? 'var(--success-color-medium, green)'
            : 'var(--error-color-medium, red)';

      const latencyDisplay =
        outbound.latency && outbound.latency > 0
          ? `${outbound.latency} ms`
          : '';

      return E(
        'div',
        {
          class: className,
          style:
            'display: flex; flex-direction: column; justify-content: space-between; padding: 12px; min-width: 0;',
        },
        [
          E(
            'div',
            {
              class: 'tachyon_dashboard-page__outbound-grid__item__header',
              style: 'margin-bottom: 8px;',
            },
            [
              E(
                'div',
                {
                  class:
                    'tachyon_dashboard-page__outbound-grid__item__title-wrapper',
                },
                [
                  E(
                    'span',
                    {
                      style: `color: ${statusColor}; font-weight: 500; font-size: 13px;`,
                    },
                    statusText,
                  ),
                ],
              ),
            ],
          ),
          E(
            'div',
            {
              class: 'tachyon_dashboard-page__outbound-grid__item__footer',
              style:
                'display: flex; align-items: center; justify-content: space-between; gap: 8px;',
            },
            [
              E(
                'div',
                {
                  class: 'tachyon_dashboard-page__outbound-grid__item__type',
                  style:
                    'overflow: hidden; text-overflow: ellipsis; white-space: nowrap;',
                },
                renderFlagEmojis(outbound.displayName),
              ),
              latencyDisplay
                ? E(
                    'div',
                    {
                      class: getLatencyClass(),
                      style: 'white-space: nowrap; flex-shrink: 0;',
                    },
                    latencyDisplay,
                  )
                : '',
            ],
          ),
        ],
      );
    }

    const isManualUrlTest = Boolean(outbound.urlTestInfo?.isManualSelection);
    const isManualPriority = Boolean(outbound.priorityInfo?.isManualSelection);
    const rawActiveServerName =
      outbound.urlTestInfo?.selectedName ||
      outbound.priorityInfo?.selectedName ||
      '';
    const selectedMemberCode =
      outbound.urlTestInfo?.selectedCode ||
      outbound.priorityInfo?.selectedCode ||
      '';
    const matchedSectionOutbound = (section.outbounds || []).find(
      (o) =>
        (selectedMemberCode && o.code === selectedMemberCode) ||
        (rawActiveServerName && o.displayName === rawActiveServerName),
    );
    const activeServerName = rawActiveServerName
      ? ensureOutboundDisplayFlag({
          displayName: rawActiveServerName,
          country: matchedSectionOutbound?.country,
          prefix: matchedSectionOutbound?.prefix,
        })
      : '';

    const modeSuffix =
      isManualUrlTest || isManualPriority
        ? `(${_('Manual')})`
        : outbound.urlTestInfo || outbound.priorityInfo
          ? `(${_('Auto')})`
          : '';
    const prefixStyle = outbound.prefix
      ? resolvePrefixBadgeStyle(outbound.prefix)
      : null;
    const outboundDisplayTitle = isAutoGroup
      ? outbound.displayName
      : ensureOutboundDisplayFlag(outbound);
    const pinnedDomains =
      !isAutoGroup && !isServiceNode && !isConnectionNode
        ? getPinnedDomainsForOutbound(section.sectionName, outbound)
        : [];

    return E(
      'div',
      {
        class: className,
        'aria-busy': outboundSwitching ? 'true' : undefined,
        'aria-disabled':
          section.withTagSelect && !canChooseOutbound ? 'true' : undefined,
        click: () =>
          canChooseOutbound &&
          onChooseOutbound(section.sectionName, section.code, outbound.code),
      },
      [
        ...(outboundSwitching
          ? [
              svgEl(
                'svg',
                { class: 'tachyon_dashboard-page__outbound-grid__item__snake' },
                [
                  svgEl('rect', {
                    width: '100%',
                    height: '100%',
                    fill: 'none',
                    rx: 4,
                    ry: 4,
                    pathLength: 100,
                  }),
                ],
              ),
            ]
          : []),
        E(
          'div',
          { class: 'tachyon_dashboard-page__outbound-grid__item__header' },
          [
            E(
              'div',
              {
                class:
                  'tachyon_dashboard-page__outbound-grid__item__title-wrapper',
              },
              [
                E('b', {}, renderFlagEmojis(outboundDisplayTitle)),
                outbound.prefix && prefixStyle
                  ? E(
                      'span',
                      {
                        class:
                          'tachyon_dashboard-page__outbound-grid__item__prefix-badge',
                        style: `background: ${prefixStyle.bg}; color: ${prefixStyle.color}; border: 1px solid ${prefixStyle.border}; font-weight: 600; cursor: pointer;`,
                        title: _('Click to customize prefix colors'),
                        click: (event: MouseEvent) =>
                          openPrefixColorPickerModal(outbound.prefix!, event),
                      },
                      renderFlagEmojis(outbound.prefix),
                    )
                  : '',
                ...(outbound.selected
                  ? [
                      E(
                        'span',
                        {
                          class:
                            'tachyon_dashboard-page__outbound-grid__item__selected-badge',
                        },
                        [
                          renderCheckIcon(10),
                          typeof document !== 'undefined' &&
                          (document.documentElement?.lang || '')
                            .toLowerCase()
                            .startsWith('ru')
                            ? 'Активен'
                            : typeof _ === 'function'
                              ? _('Active')
                              : 'Active',
                        ],
                      ),
                    ]
                  : []),
                ...(pinnedDomains.length > 0
                  ? [
                      E(
                        'span',
                        {
                          class:
                            'tachyon_dashboard-page__outbound-grid__item__prefix-badge',
                          style:
                            'background: rgba(56, 189, 248, 0.14); color: #38bdf8; border: 1px solid rgba(56, 189, 248, 0.35); font-weight: 600; cursor: pointer; display: inline-flex; align-items: center; gap: 3px;',
                          title: pinnedDomains.join(', '),
                          click: (event: MouseEvent) => {
                            event.stopPropagation();
                            openPinSitesToServerModal(section, outbound);
                          },
                        },
                        [
                          renderPinIcon(10),
                          E(
                            'span',
                            {},
                            `${pinnedDomains.slice(0, 2).join(', ')}${pinnedDomains.length > 2 ? ` +${pinnedDomains.length - 2}` : ''}`,
                          ),
                        ],
                      ),
                    ]
                  : []),
              ],
            ),
            ...(!isAutoGroup && !isServiceNode && !isConnectionNode
              ? [
                  E(
                    'button',
                    {
                      type: 'button',
                      class:
                        'btn tachyon_dashboard-page__outbound-grid__item__copy-button',
                      title:
                        pinnedDomains.length > 0
                          ? pinnedDomains.join(', ')
                          : typeof document !== 'undefined' &&
                              (document.documentElement?.lang || '')
                                .toLowerCase()
                                .startsWith('ru')
                            ? 'Привязать отдельные сайты к этому серверу'
                            : 'Pin specific sites to this server',
                      'aria-label': 'Pin sites to server',
                      style:
                        pinnedDomains.length > 0
                          ? 'color: #38bdf8;'
                          : undefined,
                      click: (event: MouseEvent) => {
                        event.stopPropagation();
                        openPinSitesToServerModal(section, outbound);
                      },
                    },
                    renderGlobeIcon(16),
                  ),
                ]
              : []),
            ...(canCopyLink
              ? [
                  E(
                    'button',
                    {
                      type: 'button',
                      class:
                        'btn tachyon_dashboard-page__outbound-grid__item__copy-button',
                      title: _('Copy proxy link'),
                      'aria-label': _('Copy proxy link'),
                      click: (event: MouseEvent) => {
                        event.stopPropagation();
                        onCopyOutbound(section, outbound);
                      },
                    },
                    renderCopyIcon24(),
                  ),
                ]
              : []),
            ...(outbound.urlTestInfo
              ? [
                  E(
                    'button',
                    {
                      type: 'button',
                      class:
                        'btn tachyon_dashboard-page__outbound-grid__item__copy-button',
                      title: _('URLTest details'),
                      'aria-label': _('URLTest details'),
                      click: (event: MouseEvent) => {
                        event.stopPropagation();
                        onShowUrlTestInfo(section, outbound);
                      },
                    },
                    renderInfoIcon24(),
                  ),
                ]
              : []),
            ...(outbound.priorityInfo
              ? [
                  E(
                    'button',
                    {
                      type: 'button',
                      class:
                        'btn tachyon_dashboard-page__outbound-grid__item__copy-button',
                      title: _('Priority details'),
                      'aria-label': _('Priority details'),
                      click: (event: MouseEvent) => {
                        event.stopPropagation();
                        onShowPriorityInfo(section, outbound);
                      },
                    },
                    renderInfoIcon24(),
                  ),
                ]
              : []),
          ],
        ),
        ...(activeServerName
          ? [
              E(
                'div',
                {
                  class:
                    'tachyon_dashboard-page__outbound-grid__item__active-server',
                  style:
                    'font-size: 13px; font-weight: 500; opacity: 0.95; margin: 4px 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: flex; align-items: center; gap: 4px;',
                  title: activeServerName,
                },
                renderFlagEmojis(activeServerName),
              ),
            ]
          : []),
        E(
          'div',
          { class: 'tachyon_dashboard-page__outbound-grid__item__footer' },
          [
            renderOutboundTypeWithPopover(
              outbound.type,
              outbound.transport,
              outbound.details,
              'tachyon_dashboard-page__outbound-grid__item__type',
              modeSuffix,
            ),
            E(
              'div',
              {
                class: [
                  getLatencyClass(),
                  !isConnectionNode
                    ? 'tachyon_dashboard-page__outbound-grid__item__latency--clickable'
                    : '',
                  isTestingSingle
                    ? 'tachyon_dashboard-page__outbound-grid__item__latency--testing'
                    : '',
                ]
                  .filter(Boolean)
                  .join(' '),
                style: isConnectionNode ? undefined : 'cursor: pointer;',
                title: isConnectionNode ? undefined : _('Test node latency'),
                'aria-label': isConnectionNode
                  ? undefined
                  : _('Test node latency'),
                click: isConnectionNode
                  ? undefined
                  : (event?: MouseEvent) => {
                      event?.stopPropagation?.();
                      event?.preventDefault?.();
                      if (isTestingSingle || latencyFetching) return;
                      onTestSingleOutbound?.(
                        section.sectionName,
                        outbound.code,
                      );
                    },
              },
              isTestingSingle
                ? [renderLoaderCircleIcon24(), E('span', {}, _('Checking...'))]
                : isConnectionNode
                  ? connectionStatusText
                  : outbound.latency && outbound.latency > 0
                    ? `${outbound.latency}ms`
                    : outbound.latency === -1 || outbound.latency < 0
                      ? _('Not responding')
                      : isServiceNode
                        ? section.serviceStatus?.ready
                          ? _('Bypass Active')
                          : section.serviceStatus?.configured
                            ? _('Stopped')
                            : '—'
                        : '—',
            ),
          ],
        ),
      ],
    );
  }

  function renderServersTable(servers: Tachyon.Outbound[]): HTMLElement {
    const isRu =
      typeof document !== 'undefined' &&
      (document.documentElement?.lang || '').toLowerCase().startsWith('ru');
    const sortKey = section.code || section.sectionName || 'default';
    const tbody = E('tbody', {});
    const colBtns = new Map<
      'name' | 'source' | 'type' | 'latency',
      HTMLElement
    >();

    const updateHeaderIndicators = () => {
      const current = sectionTableSortState.get(sortKey);
      colBtns.forEach((spanEl, col) => {
        if (current && current.col === col) {
          spanEl.textContent = current.dir === 'asc' ? ' ↑' : ' ↓';
          spanEl.style.opacity = '1';
        } else {
          spanEl.textContent = ' ↕';
          spanEl.style.opacity = '0.4';
        }
      });
    };

    const renderTableRow = (outbound: Tachyon.Outbound): HTMLElement => {
      const isTestingSingle = Boolean(
        testingOutboundCodes && testingOutboundCodes[outbound.code],
      );
      const canCopyLink =
        Boolean(outbound.canCopyLink) || isCopyableProxyLink(outbound.link);
      const selectorSwitching = Boolean(selectorSwitchingTag);
      const canChooseOutbound =
        section.withTagSelect &&
        outbound.runtimeAvailable !== false &&
        !selectorSwitching &&
        !outbound.selected;
      const outboundDisplayTitle = ensureOutboundDisplayFlag(outbound);
      const prefixStyle = outbound.prefix
        ? resolvePrefixBadgeStyle(outbound.prefix)
        : undefined;
      const pinnedDomains = getPinnedDomainsForOutbound(
        section.sectionName,
        outbound,
      );

      const getLatencyClass = () => {
        if (!outbound.latency) {
          return 'tachyon_dashboard-page__outbound-grid__item__latency tachyon_dashboard-page__outbound-grid__item__latency--empty';
        }
        if (outbound.latency === -1 || outbound.latency < 0) {
          return 'tachyon_dashboard-page__outbound-grid__item__latency tachyon_dashboard-page__outbound-grid__item__latency--red';
        }
        if (outbound.latency < 800) {
          return 'tachyon_dashboard-page__outbound-grid__item__latency tachyon_dashboard-page__outbound-grid__item__latency--green';
        }
        if (outbound.latency < 1500) {
          return 'tachyon_dashboard-page__outbound-grid__item__latency tachyon_dashboard-page__outbound-grid__item__latency--yellow';
        }
        return 'tachyon_dashboard-page__outbound-grid__item__latency tachyon_dashboard-page__outbound-grid__item__latency--red';
      };

      return E(
        'tr',
        {
          class: [
            'tachyon-dashboard-nodes-table__row',
            outbound.selected ? 'is-selected' : '',
            canChooseOutbound ? 'is-selectable' : '',
          ]
            .filter(Boolean)
            .join(' '),
          click: () => {
            if (!canChooseOutbound) return;
            onChooseOutbound(section.sectionName, section.code, outbound.code);
          },
        },
        [
          E('td', { class: 'tachyon-dashboard-nodes-table__cell--name' }, [
            E('div', { class: 'tachyon-dashboard-nodes-table__name-wrap' }, [
              ...(section.withTagSelect
                ? [
                    E('span', {
                      class: `tachyon-dashboard-nodes-table__radio ${
                        outbound.selected ? 'is-selected' : ''
                      }`,
                    }),
                  ]
                : []),
              E(
                'span',
                { class: 'tachyon-dashboard-nodes-table__name-text' },
                renderFlagEmojis(outboundDisplayTitle),
              ),
              ...(outbound.selected
                ? [
                    E(
                      'span',
                      {
                        class:
                          'tachyon_dashboard-page__outbound-grid__item__selected-badge',
                      },
                      [
                        renderCheckIcon(10),
                        isRu
                          ? 'Активен'
                          : typeof _ === 'function'
                            ? _('Active')
                            : 'Active',
                      ],
                    ),
                  ]
                : []),
              ...(pinnedDomains.length > 0
                ? [
                    E(
                      'span',
                      {
                        class:
                          'tachyon_dashboard-page__outbound-grid__item__prefix-badge',
                        style:
                          'background: rgba(56, 189, 248, 0.14); color: #38bdf8; border: 1px solid rgba(56, 189, 248, 0.35); font-weight: 600; cursor: pointer; display: inline-flex; align-items: center; gap: 3px;',
                        title: pinnedDomains.join(', '),
                        click: (event: MouseEvent) => {
                          event.stopPropagation();
                          openPinSitesToServerModal(section, outbound);
                        },
                      },
                      [
                        renderPinIcon(10),
                        E(
                          'span',
                          {},
                          `${pinnedDomains.slice(0, 2).join(', ')}${
                            pinnedDomains.length > 2
                              ? ` +${pinnedDomains.length - 2}`
                              : ''
                          }`,
                        ),
                      ],
                    ),
                  ]
                : []),
            ]),
          ]),
          E('td', { class: 'tachyon-dashboard-nodes-table__cell--source' }, [
            outbound.prefix && prefixStyle
              ? E(
                  'span',
                  {
                    class:
                      'tachyon_dashboard-page__outbound-grid__item__prefix-badge',
                    style: `background: ${prefixStyle.bg}; color: ${prefixStyle.color}; border: 1px solid ${prefixStyle.border}; font-weight: 600; cursor: pointer;`,
                    title: _('Click to customize prefix colors'),
                    click: (event: MouseEvent) => {
                      event.stopPropagation();
                      openPrefixColorPickerModal(outbound.prefix!, event);
                    },
                  },
                  renderFlagEmojis(outbound.prefix),
                )
              : E('span', { style: 'opacity: 0.45;' }, '—'),
          ]),
          E('td', { class: 'tachyon-dashboard-nodes-table__cell--type' }, [
            renderOutboundTypeWithPopover(
              outbound.type,
              outbound.transport,
              outbound.details,
              'tachyon_dashboard-page__outbound-grid__item__type',
              '',
            ),
          ]),
          E('td', { class: 'tachyon-dashboard-nodes-table__cell--latency' }, [
            E(
              'div',
              {
                class: [
                  getLatencyClass(),
                  !isConnectionNode
                    ? 'tachyon_dashboard-page__outbound-grid__item__latency--clickable'
                    : '',
                  isTestingSingle
                    ? 'tachyon_dashboard-page__outbound-grid__item__latency--testing'
                    : '',
                ]
                  .filter(Boolean)
                  .join(' '),
                style: isConnectionNode
                  ? 'display: inline-flex;'
                  : 'cursor: pointer; display: inline-flex;',
                title: isConnectionNode ? undefined : _('Test node latency'),
                click: isConnectionNode
                  ? undefined
                  : (event?: MouseEvent) => {
                      event?.stopPropagation?.();
                      event?.preventDefault?.();
                      if (isTestingSingle || latencyFetching) return;
                      onTestSingleOutbound?.(
                        section.sectionName,
                        outbound.code,
                      );
                    },
              },
              isTestingSingle
                ? [renderLoaderCircleIcon24(), E('span', {}, _('Checking...'))]
                : outbound.latency && outbound.latency > 0
                  ? `${outbound.latency}ms`
                  : outbound.latency === -1 || outbound.latency < 0
                    ? _('Not responding')
                    : '—',
            ),
          ]),
          E('td', { class: 'tachyon-dashboard-nodes-table__cell--actions' }, [
            E('div', { class: 'tachyon-dashboard-nodes-table__actions-wrap' }, [
              ...(!isServiceNode && !isConnectionNode
                ? [
                    E(
                      'button',
                      {
                        type: 'button',
                        class:
                          'btn tachyon_dashboard-page__outbound-grid__item__copy-button',
                        title:
                          pinnedDomains.length > 0
                            ? pinnedDomains.join(', ')
                            : isRu
                              ? 'Привязать отдельные сайты к этому серверу'
                              : 'Pin specific sites to this server',
                        style:
                          pinnedDomains.length > 0
                            ? 'color: #38bdf8;'
                            : undefined,
                        click: (event: MouseEvent) => {
                          event.stopPropagation();
                          openPinSitesToServerModal(section, outbound);
                        },
                      },
                      renderGlobeIcon(16),
                    ),
                  ]
                : []),
              ...(canCopyLink
                ? [
                    E(
                      'button',
                      {
                        type: 'button',
                        class:
                          'btn tachyon_dashboard-page__outbound-grid__item__copy-button',
                        title: _('Copy proxy link'),
                        'aria-label': _('Copy proxy link'),
                        click: (event: MouseEvent) => {
                          event.stopPropagation();
                          onCopyOutbound(section, outbound);
                        },
                      },
                      renderCopyIcon24(),
                    ),
                  ]
                : []),
            ]),
          ]),
        ],
      );
    };

    const populateRows = () => {
      const sortState = sectionTableSortState.get(sortKey);
      const list = [...servers];
      if (sortState) {
        const dirMul = sortState.dir === 'asc' ? 1 : -1;
        list.sort((a, b) => {
          if (sortState.col === 'name') {
            return (
              dirMul *
              String(a.displayName || a.code || '').localeCompare(
                String(b.displayName || b.code || ''),
              )
            );
          }
          if (sortState.col === 'source') {
            return (
              dirMul *
              String(a.prefix || a.sourceGroup || '').localeCompare(
                String(b.prefix || b.sourceGroup || ''),
              )
            );
          }
          if (sortState.col === 'type') {
            return (
              dirMul * String(a.type || '').localeCompare(String(b.type || ''))
            );
          }
          if (sortState.col === 'latency') {
            const rankLat = (v?: number) => {
              if (v && v > 0) return v;
              if (v === -1 || (v && v < 0)) return 999999;
              return 888888;
            };
            const la = rankLat(a.latency);
            const lb = rankLat(b.latency);
            if (la === lb) {
              return String(a.displayName || '').localeCompare(
                String(b.displayName || ''),
              );
            }
            return dirMul * (la - lb);
          }
          return 0;
        });
      }
      tbody.replaceChildren(...list.map(renderTableRow));
      updateHeaderIndicators();
    };

    const makeSortableTh = (
      col: 'name' | 'source' | 'type' | 'latency',
      label: string,
    ) => {
      const ind = E('span', { class: 'tachyon-dashboard-nodes-table__sort' });
      colBtns.set(col, ind);
      return E(
        'th',
        {
          class: `tachyon-dashboard-nodes-table__th tachyon-dashboard-nodes-table__th--sortable tachyon-dashboard-nodes-table__th--${col}`,
          style: 'cursor: pointer; user-select: none;',
          click: (e: MouseEvent) => {
            e.preventDefault();
            const cur = sectionTableSortState.get(sortKey);
            if (cur && cur.col === col) {
              sectionTableSortState.set(sortKey, {
                col,
                dir: cur.dir === 'asc' ? 'desc' : 'asc',
              });
            } else {
              sectionTableSortState.set(sortKey, { col, dir: 'asc' });
            }
            populateRows();
          },
        },
        [E('span', {}, label), ind],
      );
    };

    const thead = E('thead', {}, [
      E('tr', {}, [
        makeSortableTh('name', isRu ? 'Сервер' : _('Server')),
        makeSortableTh('source', isRu ? 'Источник' : _('Source')),
        makeSortableTh('type', isRu ? 'Протокол' : _('Protocol')),
        makeSortableTh('latency', isRu ? 'Задержка' : _('Latency')),
        E(
          'th',
          {
            class:
              'tachyon-dashboard-nodes-table__th tachyon-dashboard-nodes-table__th--actions',
          },
          isRu ? 'Действия' : _('Actions'),
        ),
      ]),
    ]);

    populateRows();

    return E(
      'div',
      {
        class: 'tachyon-dashboard-nodes-table-wrap',
        style: 'grid-column: 1 / -1; width: 100%; box-sizing: border-box;',
      },
      [E('table', { class: 'tachyon-dashboard-nodes-table' }, [thead, tbody])],
    );
  }

  function renderOutboundsList(list: Tachyon.Outbound[]): HTMLElement[] {
    if (nodesViewMode === 'table') {
      const groups: Tachyon.Outbound[] = [];
      const regularServers: Tachyon.Outbound[] = [];
      for (const item of list) {
        if (item.urlTestInfo || item.priorityInfo) {
          groups.push(item);
        } else {
          regularServers.push(item);
        }
      }
      return [
        ...groups.map((g) => renderOutbound(g)),
        ...(regularServers.length > 0
          ? [renderServersTable(regularServers)]
          : []),
      ];
    }
    return list.map((ob) => renderOutbound(ob));
  }

  const subscriptionUpdateAction = renderSubscriptionUpdateAction(
    section,
    subscriptionUpdating,
    onUpdateSubscription,
  );

  function renderGridChildren(): HTMLElement[] {
    const frozenOrder = gridFrozenOutboundOrders.get(section.code);
    let effectiveOutbounds = section.outbounds || [];
    if (
      section.dashboardSettings?.hoverFreeze !== false &&
      gridHoveredSections.has(section.code) &&
      frozenOrder &&
      frozenOrder.length > 0
    ) {
      const orderMap = new Map(frozenOrder.map((c, i) => [c, i]));
      effectiveOutbounds = [...effectiveOutbounds].sort((a, b) => {
        const idxA = orderMap.has(a.code) ? orderMap.get(a.code)! : 999999;
        const idxB = orderMap.has(b.code) ? orderMap.get(b.code)! : 999999;
        return idxA - idxB;
      });
    }

    const outbounds = effectiveOutbounds;
    const metadataList = section.subscriptionMetadata || [];
    const subSourceCount = section.subscriptionSourceCount || 0;
    const countryGrouping =
      section.dashboardSettings?.countryGrouping || 'chips';
    const chipsGrouping = section.dashboardSettings?.chipsGrouping || 'regions';
    const countryChipsLatencyMode =
      section.dashboardSettings?.countryChipsLatencyMode || 'min';

    const topGroups: Tachyon.Outbound[] = [];
    const serverOutbounds: Tachyon.Outbound[] = [];

    for (const ob of outbounds) {
      if (ob.urlTestInfo || ob.priorityInfo) {
        topGroups.push(ob);
      } else {
        serverOutbounds.push(ob);
      }
    }

    const activeOutbound = outbounds.find((o) => o.selected);
    const activeCountryCode = activeOutbound
      ? detectOutboundCountry(activeOutbound).code
      : undefined;

    const isOutboundMatchingFilters = (ob: Tachyon.Outbound) => {
      if (
        activeCountryFilter &&
        detectOutboundCountry(ob).code !== activeCountryFilter
      ) {
        return false;
      }
      if (
        chipsGrouping === 'regions' &&
        !activeCountryFilter &&
        activeRegionFilter &&
        activeRegionFilter !== 'all'
      ) {
        const c = detectOutboundCountry(ob);
        if (getCountryRegion(c.code) !== activeRegionFilter) {
          return false;
        }
      }
      return true;
    };

    const countryGroups = groupOutboundsByCountry(serverOutbounds, undefined, {
      latencyMode: countryChipsLatencyMode,
    });
    const hasMultipleCountries =
      countryGroups.length >= 2 ||
      (countryGroups.length === 1 && countryGroups[0].countryCode !== 'OTHER');

    const metadataNodes = metadataList
      .map((metadata, idx) => {
        const fallbackTitle =
          serverOutbounds[0]?.prefix ||
          (metadataList.length > 1
            ? `${_('Subscription')} #${metadata.sourceIndex || idx + 1}`
            : _('Subscription'));
        const enrichedMeta: Tachyon.SubscriptionMetadata =
          metadata.title || metadata.fileName
            ? metadata
            : { ...metadata, title: fallbackTitle };
        return renderSubscriptionMetadata(enrichedMeta, {
          onUpdateSubscription:
            subSourceCount > 0
              ? () => onUpdateSubscription(section)
              : undefined,
          subscriptionUpdating,
        });
      })
      .filter(Boolean) as HTMLElement[];

    const subMap = new Map<string, Tachyon.Outbound[]>();
    const manualOutbounds: Tachyon.Outbound[] = [];

    for (const ob of outbounds) {
      if (ob.urlTestInfo || ob.priorityInfo) {
        // already handled in topGroups
      } else if (ob.sourceGroup && ob.sourceGroup.startsWith('sub:')) {
        const list = subMap.get(ob.sourceGroup) || [];
        list.push(ob);
        subMap.set(ob.sourceGroup, list);
      } else {
        manualOutbounds.push(ob);
      }
    }

    const hasSubTaggedOutbounds = subMap.size > 0;
    const hasMultipleSources =
      subSourceCount > 1 ||
      subMap.size > 1 ||
      (hasSubTaggedOutbounds && manualOutbounds.length > 0);

    const autoCollapseKey = `autogrp:${section.code}`;
    const isAutoCollapsed = Boolean(
      collapsedSourceGroups?.has(autoCollapseKey),
    );
    const autoBlock = renderAutoGroupsBlock(topGroups, renderOutbound, {
      isCollapsed: isAutoCollapsed,
      onToggleCollapse: () => onToggleSourceGroupCollapse?.(autoCollapseKey),
    });

    const chipsCollapseKey = `countrychips:${section.code}`;
    const isChipsExpanded = Boolean(
      collapsedSourceGroups?.has(chipsCollapseKey),
    );

    // Single source sections (or sections without distinct subscription sources)
    if (!hasMultipleSources) {
      // Variant A: Country Filter Chips
      if (countryGrouping === 'chips' && hasMultipleCountries) {
        const chipsBar = renderCountryChips(
          countryGroups,
          serverOutbounds.length,
          activeCountryFilter,
          onFilterCountry,
          section.sectionName,
          {
            chipsGrouping,
            activeRegion: activeRegionFilter,
            onFilterRegion,
            activeCountryCode,
            isExpanded: isChipsExpanded,
            onToggleExpand: () =>
              onToggleSourceGroupCollapse?.(chipsCollapseKey),
          },
        );

        const visibleServers = serverOutbounds.filter(
          isOutboundMatchingFilters,
        );

        return [
          ...metadataNodes,
          ...(autoBlock ? [autoBlock] : []),
          chipsBar,
          ...renderOutboundsList(visibleServers),
        ];
      }

      // Variant B: Country Accordions
      if (countryGrouping === 'accordion' && hasMultipleCountries) {
        const nodes: HTMLElement[] = [
          ...metadataNodes,
          ...(autoBlock ? [autoBlock] : []),
        ];

        for (const group of countryGroups) {
          if (
            activeCountryFilter &&
            group.countryCode !== activeCountryFilter
          ) {
            continue;
          }
          if (
            !activeCountryFilter &&
            activeRegionFilter &&
            activeRegionFilter !== 'all' &&
            group.region !== activeRegionFilter
          ) {
            continue;
          }
          const collapseKey = `countrygrp:${section.code}:${group.countryCode}`;
          const isCountryCollapsed = Boolean(
            collapsedSourceGroups?.has(collapseKey),
          );

          nodes.push(
            renderCountryAccordionHeader(group, isCountryCollapsed, () =>
              onToggleSourceGroupCollapse?.(collapseKey),
            ),
          );

          if (!isCountryCollapsed) {
            nodes.push(...renderOutboundsList(group.outbounds));
          }
        }

        return nodes;
      }

      if (autoBlock) {
        return [
          ...metadataNodes,
          autoBlock,
          ...renderOutboundsList(
            serverOutbounds.filter(isOutboundMatchingFilters),
          ),
        ];
      }

      return [
        ...metadataNodes,
        ...renderOutboundsList(outbounds.filter(isOutboundMatchingFilters)),
      ];
    }

    // Multiple subscription sources in one section: preserve source headers on each group
    const nodes: HTMLElement[] = [...(autoBlock ? [autoBlock] : [])];

    if (countryGrouping === 'chips' && hasMultipleCountries) {
      nodes.push(
        renderCountryChips(
          countryGroups,
          serverOutbounds.length,
          activeCountryFilter,
          onFilterCountry,
          section.sectionName,
          {
            chipsGrouping,
            activeRegion: activeRegionFilter,
            onFilterRegion,
            activeCountryCode,
            isExpanded: isChipsExpanded,
            onToggleExpand: () =>
              onToggleSourceGroupCollapse?.(chipsCollapseKey),
          },
        ),
      );
    }

    const metadataBySubKey = new Map<string, Tachyon.SubscriptionMetadata>();
    metadataList.forEach((meta, idx) => {
      const sourceIdx =
        typeof meta.sourceIndex === 'number'
          ? meta.sourceIndex
          : metadataList.length === 1 && subMap.size === 1
            ? Number(Array.from(subMap.keys())[0].slice(4)) || 1
            : idx + 1;
      metadataBySubKey.set(`sub:${sourceIdx}`, meta);
    });

    const allSubKeys = Array.from(
      new Set([
        ...Array.from(subMap.keys()),
        ...Array.from(metadataBySubKey.keys()),
      ]),
    ).sort((a, b) => {
      const na = Number(a.slice(4)) || 0;
      const nb = Number(b.slice(4)) || 0;
      return na - nb;
    });

    const hasActiveCountryOrRegionFilter = Boolean(
      activeCountryFilter ||
        (chipsGrouping === 'regions' &&
          activeRegionFilter &&
          activeRegionFilter !== 'all'),
    );

    for (const subKey of allSubKeys) {
      const members = subMap.get(subKey) || [];
      const visibleMembers = members.filter(isOutboundMatchingFilters);
      const meta = metadataBySubKey.get(subKey);
      if (members.length === 0 && !meta) continue;
      if (hasActiveCountryOrRegionFilter && visibleMembers.length === 0) {
        continue;
      }

      const collapseKey = `subgrp:${section.code}:${subKey}`;
      const isGroupCollapsed = Boolean(collapsedSourceGroups?.has(collapseKey));
      const selectedMember = visibleMembers.find((m) => m.selected);
      const subNumber = Number(subKey.slice(4)) || 1;
      const fallbackSubTitle =
        allSubKeys.length > 1
          ? `${_('Subscription')} #${subNumber}`
          : _('Subscription');

      const resolvedSubTitle =
        meta?.title || members[0]?.prefix || meta?.fileName || fallbackSubTitle;
      const headerMeta: Tachyon.SubscriptionMetadata =
        meta && Object.keys(meta).length > 1
          ? {
              ...meta,
              title: meta.title || resolvedSubTitle,
            }
          : {
              title: resolvedSubTitle,
              sourceIndex: subNumber,
            };

      const metaHeader = renderSubscriptionMetadata(headerMeta, {
        groupCount: visibleMembers.length,
        selectedOutbound: selectedMember,
        isGroupCollapsed,
        onToggleGroup:
          visibleMembers.length > 0
            ? () => onToggleSourceGroupCollapse?.(collapseKey)
            : undefined,
        onUpdateSubscription:
          subSourceCount > 0 ? () => onUpdateSubscription(section) : undefined,
        subscriptionUpdating,
      });

      if (metaHeader) {
        nodes.push(metaHeader);
      }

      if (!isGroupCollapsed) {
        nodes.push(...renderOutboundsList(visibleMembers));
      }
    }

    if (manualOutbounds.length > 0) {
      const visibleManual = manualOutbounds.filter(isOutboundMatchingFilters);
      if (!hasActiveCountryOrRegionFilter || visibleManual.length > 0) {
        if (allSubKeys.length > 0) {
          const collapseKey = `subgrp:${section.code}:manual`;
          const isGroupCollapsed = Boolean(
            collapsedSourceGroups?.has(collapseKey),
          );
          const selectedManual = visibleManual.find((m) => m.selected);

          nodes.push(
            E(
              'div',
              {
                class: [
                  'tachyon_dashboard-page__subscription-meta',
                  'tachyon_dashboard-page__subscription-meta--collapsible',
                  'tachyon_dashboard-page__source-group--manual',
                  isGroupCollapsed
                    ? 'tachyon_dashboard-page__subscription-meta--collapsed'
                    : '',
                ]
                  .filter(Boolean)
                  .join(' '),
                click: () => onToggleSourceGroupCollapse?.(collapseKey),
              },
              [
                E(
                  'div',
                  { class: 'tachyon_dashboard-page__subscription-meta__main' },
                  [
                    svgEl(
                      'svg',
                      {
                        width: '15',
                        height: '15',
                        viewBox: '0 0 24 24',
                        fill: 'none',
                        stroke: 'currentColor',
                        'stroke-width': '2',
                        'stroke-linecap': 'round',
                        'stroke-linejoin': 'round',
                        style: `flex-shrink: 0; transition: transform 0.2s; transform: rotate(${isGroupCollapsed ? '-90deg' : '0deg'})`,
                      },
                      [svgEl('polyline', { points: '6 9 12 15 18 9' })],
                    ),
                    E(
                      'div',
                      {
                        class:
                          'tachyon_dashboard-page__subscription-meta__heading',
                      },
                      _('Standalone servers'),
                    ),
                    E(
                      'span',
                      { class: 'tachyon_dashboard-page__source-group__count' },
                      `${visibleManual.length}`,
                    ),
                    isGroupCollapsed && selectedManual
                      ? E(
                          'span',
                          {
                            class:
                              'tachyon_dashboard-page__source-group__active-badge',
                          },
                          `● ${selectedManual.displayName}`,
                        )
                      : '',
                  ],
                ),
              ],
            ),
          );

          if (!isGroupCollapsed) {
            nodes.push(...renderOutboundsList(visibleManual));
          }
        } else {
          nodes.push(...renderOutboundsList(visibleManual));
        }
      }
    }

    return nodes;
  }

  const canTestLatency =
    !isServiceNode &&
    (section.withTagSelect ||
      (section.outbounds && section.outbounds.length > 0));

  return E(
    'div',
    {
      class: [
        'tachyon_dashboard-page__outbound-section',
        section.configError
          ? 'tachyon_dashboard-page__outbound-section--error'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    [
      // Title with test latency (omitted when rendered inside accordion/modal with its own header)
      ...(hideSectionHeader
        ? []
        : [
            E(
              'div',
              {
                class:
                  'tachyon_dashboard-page__outbound-section__title-section',
                click: (e: MouseEvent) => {
                  if (e.target && (e.target as Element).closest('button'))
                    return;
                  onToggleCollapse?.();
                },
                style: 'cursor: pointer; user-select: none;',
              },
              [
                E(
                  'div',
                  {
                    class:
                      'tachyon_dashboard-page__outbound-section__title-section__title',
                    style: 'display: flex; align-items: center; gap: 8px;',
                  },
                  [
                    svgEl(
                      'svg',
                      {
                        width: '16',
                        height: '16',
                        viewBox: '0 0 24 24',
                        fill: 'none',
                        stroke: 'currentColor',
                        'stroke-width': '2',
                        'stroke-linecap': 'round',
                        'stroke-linejoin': 'round',
                        style: `transition: transform 0.2s; transform: rotate(${isCollapsed ? '-90deg' : '0deg'})`,
                      },
                      [svgEl('polyline', { points: '6 9 12 15 18 9' })],
                    ),
                    E('span', {}, section.displayName),
                    renderConfigErrorBadge(section),
                    isCollapsed
                      ? (() => {
                          const selectedOutbound = section.outbounds.find(
                            (o) => o.selected,
                          );
                          if (!selectedOutbound) return '';

                          const isConnectionNode =
                            !section.withTagSelect &&
                            [
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
                              'desync',
                            ].includes(section.action || '');

                          const connectionTitle =
                            (section.action &&
                              CONNECTION_ACTION_LABELS[section.action]) ||
                            selectedOutbound.displayName;

                          const isAutoGroup = Boolean(
                            selectedOutbound.urlTestInfo ||
                              selectedOutbound.priorityInfo,
                          );

                          let latencyValue = selectedOutbound.latency;
                          if (
                            (!latencyValue || latencyValue <= 0) &&
                            isAutoGroup
                          ) {
                            const info =
                              selectedOutbound.urlTestInfo ||
                              selectedOutbound.priorityInfo;
                            const member = info?.outbounds?.find(
                              (m) =>
                                m.selected ||
                                (info.selectedCode &&
                                  m.code === info.selectedCode) ||
                                (info.selectedName &&
                                  m.displayName === info.selectedName),
                            );
                            if (member && member.latency) {
                              latencyValue = member.latency;
                            }
                          }

                          function getLatencyColor() {
                            if (isConnectionNode) {
                              if (latencyFetching)
                                return 'var(--warn-color-medium, orange)';
                              if (latencyValue === -1)
                                return 'var(--error-color-medium, red)';
                              if (latencyValue && latencyValue > 0) {
                                if (latencyValue < 800)
                                  return 'var(--success-color-medium, green)';
                                if (latencyValue < 1500)
                                  return 'var(--warn-color-medium, orange)';
                                return 'var(--error-color-medium, red)';
                              }
                              return selectedOutbound!.runtimeAvailable
                                ? 'var(--success-color-medium, green)'
                                : 'var(--error-color-medium, red)';
                            }

                            if (!latencyValue)
                              return 'var(--primary-color-low, lightgray)';
                            if (latencyValue === -1 || latencyValue < 0)
                              return 'var(--error-color-medium, red)';
                            if (latencyValue < 800)
                              return 'var(--success-color-medium, green)';
                            if (latencyValue < 1500)
                              return 'var(--warn-color-medium, orange)';
                            return 'var(--error-color-medium, red)';
                          }

                          let latencyText = '';
                          if (isConnectionNode) {
                            latencyText = latencyFetching
                              ? _('Checking...')
                              : latencyValue && latencyValue > 0
                                ? `${latencyValue}ms`
                                : latencyValue === -1 || latencyValue < 0
                                  ? _('Not responding')
                                  : selectedOutbound.runtimeAvailable
                                    ? _('Connected')
                                    : _('Not connected');
                          } else {
                            latencyText =
                              latencyValue && latencyValue > 0
                                ? `${latencyValue}ms`
                                : latencyValue === -1 || latencyValue < 0
                                  ? _('Not responding')
                                  : '';
                          }

                          let badgeText = '';
                          if (isAutoGroup) {
                            const rawSubName =
                              selectedOutbound.urlTestInfo?.selectedName ||
                              selectedOutbound.priorityInfo?.selectedName ||
                              selectedOutbound.urlTestInfo?.outbounds?.find(
                                (m) =>
                                  m.selected ||
                                  (selectedOutbound.urlTestInfo?.selectedCode &&
                                    m.code ===
                                      selectedOutbound.urlTestInfo
                                        .selectedCode),
                              )?.displayName ||
                              selectedOutbound.priorityInfo?.outbounds?.find(
                                (m) =>
                                  m.selected ||
                                  (selectedOutbound.priorityInfo
                                    ?.selectedCode &&
                                    m.code ===
                                      selectedOutbound.priorityInfo
                                        .selectedCode),
                              )?.displayName ||
                              '';
                            const matchedSubOutbound = section.outbounds.find(
                              (o) =>
                                (selectedOutbound.urlTestInfo?.selectedCode &&
                                  o.code ===
                                    selectedOutbound.urlTestInfo
                                      .selectedCode) ||
                                (selectedOutbound.priorityInfo?.selectedCode &&
                                  o.code ===
                                    selectedOutbound.priorityInfo
                                      .selectedCode) ||
                                (rawSubName && o.displayName === rawSubName),
                            );
                            const activeSubName = rawSubName
                              ? ensureOutboundDisplayFlag({
                                  displayName: rawSubName,
                                  country: matchedSubOutbound?.country,
                                  prefix: matchedSubOutbound?.prefix,
                                })
                              : '';
                            badgeText = `● ${selectedOutbound.displayName}${activeSubName ? ` → ${activeSubName}` : ''}`;
                          } else if (isConnectionNode) {
                            badgeText = `● ${connectionTitle}`;
                          } else {
                            const rawName =
                              selectedOutbound.prefix ||
                              selectedOutbound.displayName ||
                              '';
                            const activeName = ensureOutboundDisplayFlag({
                              displayName: rawName,
                              country: selectedOutbound.country,
                              prefix: selectedOutbound.prefix,
                            });
                            badgeText = `● ${activeName}`;
                          }

                          return E(
                            'span',
                            {
                              class:
                                'tachyon_dashboard-page__source-group__active-badge',
                              style:
                                'text-transform: none; letter-spacing: normal; max-width: min(380px, 50vw); margin-left: 8px;',
                              title: `${badgeText.replace(/^●\s*/, '')}${latencyText ? ` • ${latencyText}` : ''}`,
                            },
                            [
                              ...renderFlagEmojis(badgeText),
                              latencyText
                                ? E(
                                    'span',
                                    {
                                      style: `color: ${getLatencyColor()}; margin-left: 4px; font-weight: 600;`,
                                    },
                                    `• ${latencyText}`,
                                  )
                                : '',
                            ],
                          );
                        })()
                      : isConnectionNode
                        ? (() => {
                            const selectedOutbound = section.outbounds.find(
                              (o) => o.selected,
                            );
                            if (!selectedOutbound) return '';
                            const connectionTitle =
                              (section.action &&
                                CONNECTION_ACTION_LABELS[section.action]) ||
                              selectedOutbound.displayName;
                            if (
                              section.displayName.toLowerCase().trim() ===
                              connectionTitle.toLowerCase().trim()
                            ) {
                              return '';
                            }
                            return E(
                              'span',
                              {
                                style:
                                  'font-size: 13px; font-weight: normal; margin-left: 8px; opacity: 0.7;',
                              },
                              connectionTitle,
                            );
                          })()
                        : '',
                  ],
                ),
                sectionStats
                  ? (() => {
                      const isRu =
                        typeof document !== 'undefined' &&
                        (document.documentElement?.lang || '')
                          .toLowerCase()
                          .startsWith('ru');
                      const selectedOutbound = section.outbounds.find(
                        (o) => o.selected,
                      );
                      const hasUrlTest = Boolean(selectedOutbound?.urlTestInfo);
                      const hasPriority = Boolean(
                        selectedOutbound?.priorityInfo,
                      );
                      const isInteractiveSelector = hasUrlTest || hasPriority;
                      const selectorLabel = hasUrlTest
                        ? selectedOutbound?.displayName || 'URLTest'
                        : hasPriority
                          ? selectedOutbound?.displayName || 'Priority'
                          : isConnectionNode
                            ? (section.action &&
                                CONNECTION_ACTION_LABELS[section.action]) ||
                              'Tunnel'
                            : isRu
                              ? 'Ручной выбор'
                              : 'Manual';

                      let latencyMs = selectedOutbound?.latency;
                      if (
                        (!latencyMs || latencyMs <= 0) &&
                        isInteractiveSelector
                      ) {
                        const info =
                          selectedOutbound?.urlTestInfo ||
                          selectedOutbound?.priorityInfo;
                        const member = info?.outbounds?.find(
                          (m) =>
                            m.selected ||
                            (info.selectedCode &&
                              m.code === info.selectedCode) ||
                            (info.selectedName &&
                              m.displayName === info.selectedName),
                        );
                        if (member && member.latency) {
                          latencyMs = member.latency;
                        }
                      }

                      const latencyBadgeClass =
                        latencyMs && latencyMs > 0
                          ? latencyMs <= 150
                            ? 'tachyon-latency-pill tachyon-latency-pill--fast'
                            : latencyMs <= 300
                              ? 'tachyon-latency-pill tachyon-latency-pill--medium'
                              : 'tachyon-latency-pill tachyon-latency-pill--slow'
                          : 'tachyon-latency-pill tachyon-latency-pill--neutral';

                      return E(
                        'div',
                        {
                          class: 'tachyon-section-row__metrics',
                          'data-section-row-metrics': section.sectionName,
                        } as Record<string, unknown>,
                        [
                          E(
                            isInteractiveSelector ? 'button' : 'span',
                            {
                              ...(isInteractiveSelector
                                ? { type: 'button' }
                                : {}),
                              class: `tachyon-section-row__selector${
                                isInteractiveSelector
                                  ? ' tachyon-section-row__selector--interactive'
                                  : ''
                              }`,
                              title: isInteractiveSelector
                                ? isRu
                                  ? 'Нажмите для просмотра деталей автовыбора'
                                  : 'Click to inspect auto-selection details'
                                : selectorLabel,
                              click: isInteractiveSelector
                                ? (ev: MouseEvent) => {
                                    ev.preventDefault();
                                    ev.stopPropagation();
                                    if (!selectedOutbound) return;
                                    if (hasUrlTest) {
                                      onShowUrlTestInfo(
                                        section,
                                        selectedOutbound,
                                      );
                                    } else if (hasPriority) {
                                      onShowPriorityInfo(
                                        section,
                                        selectedOutbound,
                                      );
                                    }
                                  }
                                : undefined,
                            } as Record<string, unknown>,
                            [
                              E(
                                'span',
                                { class: 'tachyon-section-row__selector-dot' },
                                [renderZapIcon(12)],
                              ),
                              E('span', {}, selectorLabel),
                              ...(isInteractiveSelector
                                ? [renderInfoIcon24()]
                                : []),
                            ],
                          ),
                          E(
                            'div',
                            {
                              class: 'tachyon-section-row__traffic',
                              'data-row-metric': 'traffic',
                            } as Record<string, unknown>,
                            [
                              E(
                                'span',
                                {
                                  class:
                                    'tachyon-traffic-pill tachyon-traffic-pill--down',
                                  'data-row-metric': 'session-down',
                                } as Record<string, unknown>,
                                `↓ ${prettyBytes(sectionStats.download || 0)}`,
                              ),
                              E(
                                'span',
                                {
                                  class:
                                    'tachyon-traffic-pill tachyon-traffic-pill--up',
                                  'data-row-metric': 'session-up',
                                } as Record<string, unknown>,
                                `↑ ${prettyBytes(sectionStats.upload || 0)}`,
                              ),
                            ],
                          ),
                          E(
                            'span',
                            {
                              class:
                                'tachyon-stat-pill tachyon-stat-pill--conns',
                              'data-row-metric': 'conns',
                              title: isRu
                                ? 'Активные соединения секции'
                                : 'Active section connections',
                            } as Record<string, unknown>,
                            `${sectionStats.conns} ${isRu ? 'соед.' : 'conns'}`,
                          ),
                          E(
                            'span',
                            {
                              class: latencyBadgeClass,
                              'data-row-metric': 'latency',
                            } as Record<string, unknown>,
                            latencyMs && latencyMs > 0
                              ? `${latencyMs} ms`
                              : latencyFetching
                                ? _('Checking...')
                                : '—',
                          ),
                        ],
                      );
                    })()
                  : '',
                E(
                  'div',
                  {
                    class:
                      'tachyon_dashboard-page__outbound-section__title-section__actions',
                  },
                  [
                    ...(subscriptionUpdateAction
                      ? [subscriptionUpdateAction]
                      : []),
                    ...(canTestLatency
                      ? [
                          E(
                            'button',
                            {
                              type: 'button',
                              class:
                                'btn dashboard-sections-grid-item-test-latency',
                              'data-latency-section': section.sectionName,
                              disabled: latencyFetching ? true : undefined,
                              click: (event: MouseEvent) => {
                                event.preventDefault();
                                event.stopPropagation();
                                if (latencyFetching) {
                                  return;
                                }

                                testLatency();
                              },
                            },
                            latencyFetching
                              ? [
                                  renderLoaderCircleIcon24(),
                                  E(
                                    'span',
                                    {
                                      class:
                                        'dashboard-sections-grid-item-test-latency__label',
                                    },
                                    isConnectionNode
                                      ? _('Checking...')
                                      : getLatencyTestLabel(latencyProgress),
                                  ),
                                ]
                              : E(
                                  'span',
                                  {
                                    class:
                                      'dashboard-sections-grid-item-test-latency__label',
                                  },
                                  isConnectionNode
                                    ? _('Check Connection')
                                    : _('Test latency'),
                                ),
                          ),
                        ]
                      : []),
                  ],
                ),
              ],
            ),
          ]),
      renderConfigErrorBanner(section),
      !isCollapsed
        ? E(
            'div',
            {
              class: 'tachyon_dashboard-page__outbound-grid',
              mouseenter:
                section.dashboardSettings?.hoverFreeze !== false
                  ? () => {
                      gridHoveredSections.add(section.code);
                      gridFrozenOutboundOrders.set(
                        section.code,
                        (section.outbounds || []).map((o) => o.code),
                      );
                    }
                  : undefined,
              mouseleave:
                section.dashboardSettings?.hoverFreeze !== false
                  ? () => {
                      gridHoveredSections.delete(section.code);
                      setTimeout(() => {
                        if (!gridHoveredSections.has(section.code)) {
                          gridFrozenOutboundOrders.delete(section.code);
                        }
                      }, 800);
                    }
                  : undefined,
            },
            renderGridChildren(),
          )
        : '',
    ],
  );
}

function renderConfigErrorBadge(section: Tachyon.OutboundGroup) {
  if (!section.configError) {
    return '';
  }

  return E(
    'span',
    {
      class: 'tachyon_dashboard-page__outbound-section__config-error-badge',
      title: section.configError,
    },
    _('Has errors'),
  );
}

function renderConfigErrorBanner(section: Tachyon.OutboundGroup) {
  if (!section.configError) {
    return '';
  }

  return E(
    'div',
    {
      class: 'tachyon_dashboard-page__outbound-section__error-banner',
    },
    [
      E(
        'div',
        {
          class:
            'tachyon_dashboard-page__outbound-section__error-banner__title',
          style: 'display: flex; align-items: center; gap: 6px;',
        },
        [
          renderAlertTriangleIcon(14),
          E(
            'span',
            {},
            _(
              'Section quarantined due to error (other sections continue working):',
            ),
          ),
        ],
      ),
      E(
        'div',
        {
          class: 'tachyon_dashboard-page__outbound-section__error-banner__text',
        },
        section.configError,
      ),
    ],
  );
}

export function renderSections(props: IRenderSectionsProps) {
  if (props.failed) {
    return renderFailedState();
  }

  if (props.loading) {
    return renderLoadingState();
  }

  return renderDefaultState(props);
}
