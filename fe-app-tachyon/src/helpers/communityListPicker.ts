/* eslint-disable @typescript-eslint/no-explicit-any */
import { DOMAIN_LIST_HINTS, DOMAIN_LIST_OPTIONS } from '../constants';

export interface ParsedCommunityHint {
  routeBadge: string;
  routeShort: string;
  routeKind: 'vpn' | 'dpi' | 'direct' | 'block' | 'neutral';
  description: string;
}

export function parseCommunityHint(rawHint: string): ParsedCommunityHint {
  const raw = String(rawHint || '').trim();
  const match = raw.match(/^\[([^\]]+)\]\s*(.*)$/);
  const routeBadge = match ? match[1].replace(/^Маршрут:\s*/i, '').trim() : '';
  const description = match ? match[2].trim() : raw;

  const lower = routeBadge.toLowerCase();
  let routeKind: ParsedCommunityHint['routeKind'] = 'neutral';
  let routeShort = '';

  if (lower.includes('(block)') || lower.startsWith('блокировать')) {
    routeKind = 'block';
    routeShort = 'Block';
  } else if (
    lower.includes('строго напрямую') ||
    lower.startsWith('напрямую')
  ) {
    routeKind = 'direct';
    routeShort = 'Direct';
  } else if (lower.includes('обход dpi') || lower.includes('zapret')) {
    routeKind = 'dpi';
    routeShort = 'VPN / DPI';
  } else if (
    lower.includes('прокси') ||
    lower.includes('vpn') ||
    lower.includes('геоблок')
  ) {
    routeKind = 'vpn';
    routeShort = 'VPN';
  }

  return {
    routeBadge,
    routeShort,
    routeKind,
    description,
  };
}

export interface CommunityListCategory {
  id: string;
  titleRu: string;
  titleEn: string;
  keys: Array<keyof typeof DOMAIN_LIST_OPTIONS>;
}

/**
 * Exact 100% inclusion map verified against compiled tachyon-lists rulesets:
 * when a parent superset list is selected, every child list whose rules (domains,
 * suffixes, keywords, regexes, and subnets) are 100% covered by the parent
 * becomes redundant and is visually dimmed + disabled to avoid duplicates.
 */
export const COMMUNITY_LIST_SUPERSETS: Readonly<
  Record<string, readonly string[]>
> = {
  // russia_inside is domain-only and 100% covers these domain-only lists
  // (ru_blocked, refilter, antifilter also have IP subnets, so they are only 100% covered
  // when combined or in domain-only mode; geoblock/block/xai/hdrezka/anime/news are domain-only)
  russia_inside: ['geoblock', 'block', 'xai', 'hdrezka', 'anime', 'news'],
  geoblock: ['xai'],
  // ru_blocked_all 100% covers both domains and subnets of antifilter
  ru_blocked_all: ['antifilter'],
  // russia_outside 100% covers all domains of ru_only_inside
  russia_outside: ['ru_only_inside'],
  // ru_domains 100% covers geosite_ru and ru_only_inside (plus adds RU IP subnets)
  ru_domains: ['geosite_ru', 'ru_only_inside'],
  // geosite_ru 100% covers ru_only_inside
  geosite_ru: ['ru_only_inside'],
  // ai_all 100% covers openai, anthropic, and xai
  ai_all: ['openai', 'anthropic', 'xai'],
  // twitch 100% covers twitch_ads
  twitch: ['twitch_ads'],
};

/**
 * Returns a Map from each redundant child list key to the array of currently selected
 * superset list keys that 100% include it.
 */
export function getSubsumedCommunityLists(
  selectedKeys: Iterable<string>,
): Map<string, string[]> {
  const selectedSet = new Set(selectedKeys);
  const subsumedBy = new Map<string, string[]>();

  for (const parentKey of selectedSet) {
    const children = COMMUNITY_LIST_SUPERSETS[parentKey];
    if (!children) continue;
    for (const childKey of children) {
      if (childKey === parentKey) continue;
      const existing = subsumedBy.get(childKey);
      if (existing) {
        if (!existing.includes(parentKey)) {
          existing.push(parentKey);
        }
      } else {
        subsumedBy.set(childKey, [parentKey]);
      }
    }
  }

  return subsumedBy;
}

export const COMMUNITY_LIST_CATEGORIES: CommunityListCategory[] = [
  {
    id: 'popular',
    titleRu: '⚡ Популярные',
    titleEn: '⚡ Popular',
    keys: [
      'russia_inside',
      'geoblock',
      'youtube',
      'discord',
      'telegram',
      'ai_all',
      'openai',
      'meta',
      'twitter',
      'spotify',
      'steam',
      'cloudflare',
      'ru_whitelist',
    ],
  },
  {
    id: 'blocked',
    titleRu: '🛡️ Реестры и Геоблок',
    titleEn: '🛡️ Registries & Geoblock',
    keys: [
      'russia_inside',
      'geoblock',
      'ru_blocked',
      'block',
      'antifilter',
      'refilter',
      'ru_blocked_all',
    ],
  },
  {
    id: 'ai',
    titleRu: '🤖 ИИ и Нейросети',
    titleEn: '🤖 AI Services',
    keys: ['ai_all', 'openai', 'anthropic', 'google_ai', 'xai'],
  },
  {
    id: 'media',
    titleRu: '🎬 Видео, Музыка и Соцсети',
    titleEn: '🎬 Video, Music & Social',
    keys: [
      'youtube',
      'discord',
      'telegram',
      'meta',
      'twitter',
      'twitch',
      'twitch_ads',
      'spotify',
      'netflix',
      'tiktok',
      'hdrezka',
      'anime',
      'pinterest',
    ],
  },
  {
    id: 'games',
    titleRu: '🎮 Игры и Лаунчеры',
    titleEn: '🎮 Games & Launchers',
    keys: [
      'steam',
      'epicgames',
      'riot',
      'origin',
      'roblox',
      'supercell',
      'escapefromtarkov',
      'faceit',
    ],
  },
  {
    id: 'infra',
    titleRu: '☁️ CDN, Облака и IT',
    titleEn: '☁️ CDN, Cloud & IT',
    keys: [
      'cloudflare',
      'cloudfront',
      'fastly',
      'hetzner',
      'ovh',
      'digitalocean',
      'github',
      'docker',
      'apple',
      'microsoft',
      'google_play',
      'hodca',
    ],
  },
  {
    id: 'direct',
    titleRu: '🏠 Прямой доступ (РФ / Push)',
    titleEn: '🏠 Direct Route (RU / Push)',
    keys: [
      'ru_whitelist',
      'ru_domains',
      'ru_only_inside',
      'russia_outside',
      'push',
    ],
  },
  {
    id: 'other',
    titleRu: '🔒 Прочее и Реклама',
    titleEn: '🔒 Other & Adblock',
    keys: ['news', 'torrent', 'tor', 'porn', 'ads_hagezi_pro', 'win_spy'],
  },
];

function isRussianLocale(): boolean {
  try {
    const lang = String(
      (globalThis as any).L?.env?.lang || document.documentElement.lang || 'ru',
    ).toLowerCase();
    return !lang.startsWith('en');
  } catch (_e) {
    return true;
  }
}

export function createInteractiveHintBanner(): {
  element: HTMLElement;
  showHint: (key: string, subsumedParents?: string[]) => void;
} {
  const ru = isRussianLocale();
  const titleEl = E(
    'span',
    { class: 'tachyon-ruleset-picker__hint-title' },
    ru
      ? '💡 Наведите курсор на список (или нажмите ⓘ на телефоне), чтобы увидеть состав и рекомендуемый маршрут'
      : '💡 Hover over any service list (or tap ⓘ on mobile) to inspect included domains and recommended routing',
  );
  const badgeEl = E('span', {
    class: 'tachyon-ruleset-picker__hint-badge',
    style: 'display:none;',
  });
  const descEl = E(
    'div',
    { class: 'tachyon-ruleset-picker__hint-desc' },
    ru
      ? 'Нажимайте на плашки сервисов ниже для быстрого выбора в один клик.'
      : 'Click any service chip below to toggle it with a single click.',
  );

  const bannerEl = E('div', { class: 'tachyon-ruleset-picker__hint-bar' }, [
    E('div', { class: 'tachyon-ruleset-picker__hint-head' }, [
      titleEl,
      badgeEl,
    ]),
    descEl,
  ]);

  function showHint(key: string, subsumedParents?: string[]) {
    const label =
      (DOMAIN_LIST_OPTIONS as Record<string, string>)[key] || String(key || '');
    const rawHint = DOMAIN_LIST_HINTS[key] || '';
    const parentLabels = (subsumedParents || []).map(
      (p) => (DOMAIN_LIST_OPTIONS as Record<string, string>)[p] || p,
    );
    const subsumedPrefix =
      parentLabels.length > 0
        ? ru
          ? `🔒 Полностью входит в выбранный список «${parentLabels.join('», «')}» (выбор не требуется). `
          : `🔒 100% included in selected list "${parentLabels.join('", "')}" (already covered). `
        : '';

    if (!rawHint) {
      titleEl.textContent = label;
      badgeEl.style.display = 'none';
      descEl.textContent = subsumedPrefix;
      return;
    }
    const parsed = parseCommunityHint(rawHint);
    titleEl.textContent = `${label} (${key})`;
    if (parentLabels.length > 0) {
      badgeEl.textContent = ru
        ? `Входит в: ${parentLabels.join(', ')}`
        : `Included in: ${parentLabels.join(', ')}`;
      badgeEl.className = 'tachyon-ruleset-picker__hint-badge is-subsumed';
      badgeEl.style.display = 'inline-flex';
    } else if (parsed.routeBadge) {
      badgeEl.textContent = parsed.routeBadge;
      badgeEl.className = `tachyon-ruleset-picker__hint-badge is-${parsed.routeKind}`;
      badgeEl.style.display = 'inline-flex';
    } else {
      badgeEl.style.display = 'none';
    }
    descEl.textContent = `${subsumedPrefix}${parsed.description}`;
    bannerEl.classList.add('is-highlighted');
  }

  return { element: bannerEl, showHint };
}

export function attachCommunityListPicker(
  option: any,
  opts: {
    getBlockedKeys?: (sectionId: string) => Set<string>;
  } = {},
): void {
  if (!option || option.__tachyonPickerAttached) {
    return;
  }
  option.__tachyonPickerAttached = true;

  const origRenderWidget = option.renderWidget;
  if (typeof origRenderWidget !== 'function') {
    return;
  }

  option.renderWidget = function (
    section_id: string,
    option_index: number,
    cfgvalue: any,
  ) {
    const widgetNode = origRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );

    try {
      const ru = isRussianLocale();
      const blocked = opts.getBlockedKeys
        ? opts.getBlockedKeys(section_id)
        : new Set<string>();

      let activeCategory = 'popular';

      const { element: hintBanner, showHint } = createInteractiveHintBanner();

      const getValues = (): string[] => {
        try {
          const uiEl = this.getUIElement(section_id);
          if (uiEl && typeof uiEl.getValue === 'function') {
            const val = uiEl.getValue();
            if (Array.isArray(val)) return val.map(String).filter(Boolean);
            if (val) return [String(val)];
            return [];
          }
        } catch (_e) {
          /* ignore */
        }
        if (Array.isArray(cfgvalue))
          return cfgvalue.map(String).filter(Boolean);
        if (typeof cfgvalue === 'string' && cfgvalue.trim()) {
          return cfgvalue.trim().split(/\s+/);
        }
        return [];
      };

      const setValues = (nextValues: string[], changedKey?: string) => {
        try {
          const uiEl = this.getUIElement(section_id);
          if (uiEl && typeof uiEl.setValue === 'function') {
            uiEl.setValue(nextValues);
            if (uiEl.node) {
              uiEl.node.dispatchEvent(
                new CustomEvent('widget-change', { bubbles: true }),
              );
            }
          }
          if (typeof this.onchange === 'function') {
            this.onchange(new Event('change'), section_id, nextValues);
          }
        } catch (_e) {
          /* ignore */
        }
        if (changedKey) {
          showHint(changedKey);
        }
        syncChipStates();
        decorateNativeDynamicListItems();
      };

      let searchQuery = '';

      const toggleKey = (key: string) => {
        const current = getValues();
        const subsumedMap = getSubsumedCommunityLists(current);
        if (subsumedMap.has(key) && !current.includes(key)) {
          showHint(key, subsumedMap.get(key));
          return;
        }
        const exists = current.includes(key);
        let next = exists
          ? current.filter((k) => k !== key)
          : [...current, key];
        // Automatically prune any child lists that are now 100% covered by the new selection
        const nextSubsumed = getSubsumedCommunityLists(next);
        if (nextSubsumed.size > 0) {
          next = next.filter((k) => !nextSubsumed.has(k));
        }
        setValues(next, key);
      };

      const chipsContainer = E('div', {
        class: 'tachyon-ruleset-picker__grid',
      });
      const catTabsContainer = E('div', {
        class: 'tachyon-ruleset-picker__cats',
      });
      const searchInput = E('input', {
        type: 'search',
        class: 'cbi-input-text tachyon-ruleset-picker__search',
        placeholder: ru
          ? '🔍 Быстрый поиск списка по названию, сервису или домену (например: youtube, openai, игра, геоблок)...'
          : '🔍 Filter lists by name, service, or domain (e.g. youtube, openai, game, geoblock)...',
        input: (ev: Event) => {
          searchQuery = (ev.target as HTMLInputElement).value || '';
          renderChips();
        },
      } as any) as HTMLInputElement;

      function syncChipStates() {
        const currentVals = getValues();
        const selectedSet = new Set(currentVals);
        const subsumedMap = getSubsumedCommunityLists(selectedSet);
        const buttons = chipsContainer.querySelectorAll<HTMLButtonElement>(
          '.tachyon-ruleset-picker__chip[data-key]',
        );
        buttons.forEach((btn) => {
          const key = btn.getAttribute('data-key') || '';
          const subsumedParents = subsumedMap.get(key);
          const isSubsumed = Boolean(
            subsumedParents && subsumedParents.length > 0,
          );
          const isSel = selectedSet.has(key) && !isSubsumed;
          btn.classList.toggle('is-selected', isSel);
          btn.classList.toggle('is-subsumed', isSubsumed);
          btn.disabled = isSubsumed;
          btn.setAttribute('aria-disabled', isSubsumed ? 'true' : 'false');

          const rawHint = DOMAIN_LIST_HINTS[key] || '';
          if (isSubsumed && subsumedParents) {
            const parentLabels = subsumedParents.map(
              (p) => (DOMAIN_LIST_OPTIONS as Record<string, string>)[p] || p,
            );
            const subNote = ru
              ? `[Уже входит в: ${parentLabels.join(', ')}] `
              : `[Already included in: ${parentLabels.join(', ')}] `;
            btn.title = subNote + rawHint;
          } else {
            btn.title = rawHint;
          }

          const checkEl = btn.querySelector(
            '.tachyon-ruleset-picker__chip-check',
          );
          if (checkEl) {
            checkEl.textContent = isSubsumed ? '⊂' : isSel ? '✓' : '+';
          }
        });
      }

      function renderCategoryTabs() {
        catTabsContainer.innerHTML = '';
        const allCats: Array<{ id: string; label: string }> = [
          ...COMMUNITY_LIST_CATEGORIES.map((c) => ({
            id: c.id,
            label: ru ? c.titleRu : c.titleEn,
          })),
          {
            id: 'all',
            label: ru ? '📋 Все списки (50+)' : '📋 All Lists (50+)',
          },
        ];

        allCats.forEach((cat) => {
          const isAct = activeCategory === cat.id && !searchQuery.trim();
          catTabsContainer.appendChild(
            E(
              'button',
              {
                type: 'button',
                class: `tachyon-ruleset-picker__cat-btn ${isAct ? 'is-active' : ''}`,
                click: () => {
                  activeCategory = cat.id;
                  if (searchQuery.trim()) {
                    searchQuery = '';
                    searchInput.value = '';
                  }
                  renderCategoryTabs();
                  renderChips();
                },
              },
              cat.label,
            ),
          );
        });
      }

      function renderChips() {
        chipsContainer.innerHTML = '';
        const currentVals = getValues();
        const selectedSet = new Set(currentVals);
        const subsumedMap = getSubsumedCommunityLists(selectedSet);

        let keysToShow: string[] = [];
        const q = searchQuery.trim().toLowerCase();
        if (q) {
          keysToShow = Object.keys(DOMAIN_LIST_OPTIONS).filter((key) => {
            if (blocked.has(key)) return false;
            const label = String(
              (DOMAIN_LIST_OPTIONS as Record<string, string>)[key] || '',
            ).toLowerCase();
            const hint = String(DOMAIN_LIST_HINTS[key] || '').toLowerCase();
            return (
              key.toLowerCase().includes(q) ||
              label.includes(q) ||
              hint.includes(q)
            );
          });
        } else if (activeCategory === 'all') {
          keysToShow = Object.keys(DOMAIN_LIST_OPTIONS).filter(
            (key) => !blocked.has(key),
          );
        } else {
          const catObj =
            COMMUNITY_LIST_CATEGORIES.find((c) => c.id === activeCategory) ||
            COMMUNITY_LIST_CATEGORIES[0];
          keysToShow = catObj.keys
            .map(String)
            .filter((key) => !blocked.has(key));
        }

        if (keysToShow.length === 0) {
          chipsContainer.appendChild(
            E(
              'div',
              { class: 'tachyon-ruleset-picker__empty' },
              ru
                ? 'Ничего не найдено по запросу'
                : 'No matching service lists found',
            ),
          );
          return;
        }

        keysToShow.forEach((key) => {
          const label =
            (DOMAIN_LIST_OPTIONS as Record<string, string>)[key] || key;
          const rawHint = DOMAIN_LIST_HINTS[key] || '';
          const parsed = parseCommunityHint(rawHint);
          const subsumedParents = subsumedMap.get(key);
          const isSubsumed = Boolean(
            subsumedParents && subsumedParents.length > 0,
          );
          const isSel = selectedSet.has(key) && !isSubsumed;
          const parentLabels = (subsumedParents || []).map(
            (p) => (DOMAIN_LIST_OPTIONS as Record<string, string>)[p] || p,
          );
          const chipTitle = isSubsumed
            ? (ru
                ? `[Уже входит в: ${parentLabels.join(', ')}] `
                : `[Already included in: ${parentLabels.join(', ')}] `) +
              rawHint
            : rawHint;

          const infoBtn = E(
            'span',
            {
              class: 'tachyon-ruleset-picker__chip-info',
              title: chipTitle,
              role: 'button',
              tabindex: '0',
              click: (ev: Event) => {
                ev.preventDefault();
                ev.stopPropagation();
                showHint(key, subsumedMap.get(key));
              },
            } as any,
            'ⓘ',
          );

          const chipBtn = E(
            'button',
            {
              type: 'button',
              class: `tachyon-ruleset-picker__chip ${isSel ? 'is-selected' : ''} ${isSubsumed ? 'is-subsumed' : ''}`,
              'data-key': key,
              disabled: isSubsumed ? true : undefined,
              'aria-disabled': isSubsumed ? 'true' : 'false',
              title: chipTitle,
              mouseenter: () => showHint(key, subsumedMap.get(key)),
              focus: () => showHint(key, subsumedMap.get(key)),
              click: () => toggleKey(key),
            } as any,
            [
              E(
                'span',
                { class: 'tachyon-ruleset-picker__chip-check' },
                isSubsumed ? '⊂' : isSel ? '✓' : '+',
              ),
              E('span', { class: 'tachyon-ruleset-picker__chip-label' }, label),
              isSubsumed
                ? E(
                    'span',
                    {
                      class: 'tachyon-ruleset-picker__chip-route is-subsumed',
                    },
                    ru
                      ? `⊂ ${subsumedParents![0]}`
                      : `⊂ ${subsumedParents![0]}`,
                  )
                : parsed.routeShort
                  ? E(
                      'span',
                      {
                        class: `tachyon-ruleset-picker__chip-route is-${parsed.routeKind}`,
                      },
                      parsed.routeShort,
                    )
                  : '',
              infoBtn,
            ],
          );

          chipsContainer.appendChild(chipBtn);
        });
      }

      function decorateNativeDynamicListItems() {
        if (!(widgetNode instanceof HTMLElement)) return;
        widgetNode.classList.add('tachyon-dynlist-with-picker');
        const items = widgetNode.querySelectorAll<HTMLElement>(
          ':scope > .item, .cbi-dynlist > .item, .cbi-dynlist li[data-value]',
        );
        items.forEach((itemEl) => {
          const hiddenInput = itemEl.querySelector<HTMLInputElement>(
            'input[type="hidden"]',
          );
          const key =
            itemEl.getAttribute('data-value') || hiddenInput?.value || '';
          const rawHint = DOMAIN_LIST_HINTS[key];
          if (!rawHint) return;
          itemEl.setAttribute('title', rawHint);
          if (!itemEl.dataset.tachyonHintBound) {
            itemEl.dataset.tachyonHintBound = '1';
            itemEl.addEventListener('mouseenter', () => showHint(key));
          }
        });

        const selectEl = widgetNode.querySelector<HTMLSelectElement>('select');
        if (selectEl && !selectEl.dataset.tachyonHintBound) {
          selectEl.dataset.tachyonHintBound = '1';
          selectEl.addEventListener('change', () => {
            const v = selectEl.value;
            if (v && DOMAIN_LIST_HINTS[v]) {
              showHint(v);
            }
          });
        }
      }

      renderCategoryTabs();
      renderChips();

      const pickerWrapper = E('div', { class: 'tachyon-ruleset-picker' }, [
        hintBanner,
        E('div', { class: 'tachyon-ruleset-picker__cats-block' }, [
          E('div', { class: 'tachyon-ruleset-picker__toolbar' }, [
            searchInput,
            catTabsContainer,
          ]),
        ]),
        E('div', { class: 'tachyon-ruleset-picker__list-block' }, [
          chipsContainer,
        ]),
      ]);

      const attachToDom = () => {
        if (!(widgetNode instanceof HTMLElement)) return;
        widgetNode.classList.add('tachyon-dynlist-with-picker');
        const parent = widgetNode.parentNode;
        if (parent) {
          if (pickerWrapper.parentNode !== parent) {
            parent.insertBefore(pickerWrapper, widgetNode.nextSibling);
          }
        } else if (pickerWrapper.parentNode !== widgetNode) {
          const addItemEl = widgetNode.querySelector(':scope > .add-item');
          if (addItemEl) {
            widgetNode.insertBefore(pickerWrapper, addItemEl);
          } else {
            widgetNode.appendChild(pickerWrapper);
          }
        }
        syncChipStates();
        decorateNativeDynamicListItems();
      };

      Promise.resolve()
        .then(() => Promise.resolve())
        .then(attachToDom);
      setTimeout(attachToDom, 0);

      if (widgetNode instanceof HTMLElement) {
        widgetNode.addEventListener('click', () => {
          setTimeout(() => {
            syncChipStates();
            decorateNativeDynamicListItems();
          }, 30);
        });
        widgetNode.addEventListener('change', () => {
          setTimeout(() => {
            syncChipStates();
            decorateNativeDynamicListItems();
          }, 30);
        });
        widgetNode.addEventListener('cbi-dynlist-change', () => {
          setTimeout(() => {
            syncChipStates();
            decorateNativeDynamicListItems();
          }, 15);
        });
      }
    } catch (_err) {
      /* keep original widget working even if enhancement fails */
    }

    return widgetNode;
  };
}
