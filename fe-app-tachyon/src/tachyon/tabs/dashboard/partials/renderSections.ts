import {
  renderLoaderCircleIcon24,
  renderCopyIcon24,
  renderLinkIcon24,
  renderInfoIcon24,
} from '../../../../icons';
import {
  isCopyableProxyLink,
  openPrefixColorPickerModal,
  renderOutboundTypeWithPopover,
  resolvePrefixBadgeStyle,
  svgEl,
} from '../../../../helpers';
import { prettyBytes } from '../../../../helpers/prettyBytes';
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

function renderMetadataAction(label: string, url?: string) {
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
    renderLinkIcon24(),
  );
}

function renderSubscriptionMetadata(
  metadata: Tachyon.SubscriptionMetadata | undefined,
  options?: {
    groupCount?: number;
    selectedOutbound?: Tachyon.Outbound;
    isGroupCollapsed?: boolean;
    onToggleGroup?: () => void;
  },
) {
  if (!metadata || Object.keys(metadata).length <= 1) {
    if (!options?.onToggleGroup) {
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

  const rows = [
    traffic
      ? {
          label: _('Traffic'),
          value: `${used} / ${total}`,
        }
      : undefined,
    expire ? { label: _('Expires'), value: expire } : undefined,
    refillDate ? { label: _('Refill'), value: refillDate } : undefined,
  ].filter(Boolean) as { label: string; value: string }[];

  const actions = [
    renderMetadataAction('Profile', metadata?.webPageUrl),
    renderMetadataAction('Support', metadata?.supportUrl),
    renderMetadataAction('More details', metadata?.announceUrl),
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
        E(
          'div',
          { class: 'tachyon_dashboard-page__subscription-meta__heading' },
          _('Subscription info:'),
        ),
        title
          ? E(
              'div',
              { class: 'tachyon_dashboard-page__subscription-meta__title' },
              title,
            )
          : '',
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
                class: 'tachyon_dashboard-page__source-group__active-badge',
              },
              `● ${options.selectedOutbound.displayName}`,
            )
          : '',
        rows.length
          ? E(
              'div',
              { class: 'tachyon_dashboard-page__subscription-meta__facts' },
              rows.map((row) =>
                E(
                  'div',
                  { class: 'tachyon_dashboard-page__subscription-meta__fact' },
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
              ),
            )
          : '',
        actions.length
          ? E(
              'div',
              { class: 'tachyon_dashboard-page__subscription-meta__actions' },
              actions,
            )
          : '',
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
    ? `${activeCountryGroup.countryFlag || '🌐'} ${activeCountryGroup.countryName || activeCountryGroup.countryCode}`
    : activeRegionMeta
      ? `${activeRegionMeta.flag} ${activeRegionMeta.label}`
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
          E('span', { class: 'tachyon_dashboard-page__flag-emoji' }, reg.flag),
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
        },
        '🌐',
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
          },
          group.countryFlag || '🌐',
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
        E(
          'div',
          {
            class: 'tachyon_dashboard-page__outbound-section__title-section',
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
                        typeof document !== 'undefined' &&
                          (document.documentElement?.lang || '')
                            .toLowerCase()
                            .startsWith('ru')
                          ? '✓ Активен'
                          : typeof _ === 'function'
                            ? _('✓ Active')
                            : '✓ Active',
                      ),
                    ]
                  : []),
              ],
            ),
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
      .map((metadata) => renderSubscriptionMetadata(metadata))
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
          ...visibleServers.map((ob) => renderOutbound(ob)),
        ];
      }

      // Variant B: Country Accordions
      if (countryGrouping === 'accordion' && hasMultipleCountries) {
        const nodes: HTMLElement[] = [
          ...metadataNodes,
          ...(autoBlock ? [autoBlock] : []),
        ];

        for (const group of countryGroups) {
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
            for (const m of group.outbounds) {
              nodes.push(renderOutbound(m));
            }
          }
        }

        return nodes;
      }

      if (autoBlock) {
        return [
          ...metadataNodes,
          autoBlock,
          ...serverOutbounds.map((ob) => renderOutbound(ob)),
        ];
      }

      return [...metadataNodes, ...outbounds.map((ob) => renderOutbound(ob))];
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

    for (const subKey of allSubKeys) {
      const members = subMap.get(subKey) || [];
      const meta = metadataBySubKey.get(subKey);
      if (members.length === 0 && !meta) continue;

      const collapseKey = `subgrp:${section.code}:${subKey}`;
      const isGroupCollapsed = Boolean(collapsedSourceGroups?.has(collapseKey));
      const selectedMember = members.find((m) => m.selected);
      const subNumber = Number(subKey.slice(4)) || 1;
      const fallbackSubTitle =
        allSubKeys.length > 1
          ? `${_('Subscription')} #${subNumber}`
          : _('Subscription');

      const headerMeta =
        meta && Object.keys(meta).length > 1
          ? meta
          : ({
              title: members[0]?.prefix || fallbackSubTitle,
              sourceIndex: subNumber,
            } as Tachyon.SubscriptionMetadata);

      const metaHeader = renderSubscriptionMetadata(headerMeta, {
        groupCount: members.length,
        selectedOutbound: selectedMember,
        isGroupCollapsed,
        onToggleGroup:
          members.length > 0
            ? () => onToggleSourceGroupCollapse?.(collapseKey)
            : undefined,
      });

      if (metaHeader) {
        nodes.push(metaHeader);
      }

      if (!isGroupCollapsed) {
        const visibleMembers =
          countryGrouping === 'chips'
            ? members.filter(isOutboundMatchingFilters)
            : members;
        for (const m of visibleMembers) {
          nodes.push(renderOutbound(m));
        }
      }
    }

    if (manualOutbounds.length > 0) {
      if (allSubKeys.length > 0) {
        const collapseKey = `subgrp:${section.code}:manual`;
        const isGroupCollapsed = Boolean(
          collapsedSourceGroups?.has(collapseKey),
        );
        const selectedManual = manualOutbounds.find((m) => m.selected);

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
                    `${manualOutbounds.length}`,
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
          const visibleManual =
            countryGrouping === 'chips'
              ? manualOutbounds.filter(isOutboundMatchingFilters)
              : manualOutbounds;
          for (const m of visibleManual) {
            nodes.push(renderOutbound(m));
          }
        }
      } else {
        const visibleManual =
          countryGrouping === 'chips'
            ? manualOutbounds.filter(isOutboundMatchingFilters)
            : manualOutbounds;
        for (const m of visibleManual) {
          nodes.push(renderOutbound(m));
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
      // Title with test latency
      E(
        'div',
        {
          class: 'tachyon_dashboard-page__outbound-section__title-section',
          click: (e: MouseEvent) => {
            if (e.target && (e.target as Element).closest('button')) return;
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
                    if ((!latencyValue || latencyValue <= 0) && isAutoGroup) {
                      const info =
                        selectedOutbound.urlTestInfo ||
                        selectedOutbound.priorityInfo;
                      const member = info?.outbounds?.find(
                        (m) =>
                          m.selected ||
                          (info.selectedCode && m.code === info.selectedCode) ||
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
                                selectedOutbound.urlTestInfo.selectedCode),
                        )?.displayName ||
                        selectedOutbound.priorityInfo?.outbounds?.find(
                          (m) =>
                            m.selected ||
                            (selectedOutbound.priorityInfo?.selectedCode &&
                              m.code ===
                                selectedOutbound.priorityInfo.selectedCode),
                        )?.displayName ||
                        '';
                      const matchedSubOutbound = section.outbounds.find(
                        (o) =>
                          (selectedOutbound.urlTestInfo?.selectedCode &&
                            o.code ===
                              selectedOutbound.urlTestInfo.selectedCode) ||
                          (selectedOutbound.priorityInfo?.selectedCode &&
                            o.code ===
                              selectedOutbound.priorityInfo.selectedCode) ||
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
          E(
            'div',
            {
              class:
                'tachyon_dashboard-page__outbound-section__title-section__actions',
            },
            [
              ...(subscriptionUpdateAction ? [subscriptionUpdateAction] : []),
              ...(canTestLatency
                ? [
                    E(
                      'button',
                      {
                        type: 'button',
                        class: 'btn dashboard-sections-grid-item-test-latency',
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
        },
        `⚠️ ${_('Section quarantined due to error (other sections continue working):')}`,
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
