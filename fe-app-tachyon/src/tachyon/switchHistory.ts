import { renderRefreshCwIcon } from '../icons';
import {
  buildRuntimeTagDisplayContextFromUci,
  humanizeRuntimeTag,
} from './helpers/humanizeTag';
import { tr } from './helpers/i18n';
import { callBaseMethod } from './methods/shell/callBaseMethod';
import { Tachyon } from './types';

export interface SwitchEvent {
  timestamp: number;
  group: string;
  group_display_name?: string;
  from: string;
  from_display_name?: string;
  to: string;
  to_display_name?: string;
  reason: string;
  decided_at?: number;
  source: string;
  observed: boolean;
  priority?: boolean;
  old_level?: number;
  new_level?: number;
  from_delay_ms?: number;
  to_delay_ms?: number;
  from_delay_at?: string;
  to_delay_at?: string;
  check_urls?: string[];
  from_quarantined?: boolean;
  to_quarantined?: boolean;
  on_backup?: boolean;
  primary?: string;
  primary_display_name?: string;
  primary_healthy?: boolean;
  primary_failures?: number;
  previous_switch_at?: number;
}

export function reasonLabel(reason: string): string {
  switch (reason) {
    case 'initial':
      return tr('Первичный выбор', 'Initial selection');
    case 'failover':
      return tr('Переход на резерв', 'Failover');
    case 'recovery':
      return tr('Восстановление', 'Recovery');
    case 'faster_same_tier':
      return tr(
        'Более быстрый узел того же уровня',
        'Faster node in the same tier',
      );
    case 'switch':
      return tr('Переключение', 'Switch');
    case 'active_ineligible':
    case 'active_unhealthy':
      return tr('Активный узел недоступен', 'Active node unavailable');
    case 'higher_priority_eligible':
      return tr(
        'Возврат на более приоритетный узел',
        'Returned to higher-priority node',
      );
    case 'manual_restore':
      return tr(
        'Ручной возврат на основной узел',
        'Manual restore to primary node',
      );
    default:
      return tr('Причина неизвестна', 'Unknown reason');
  }
}

function transitionLabel(event: SwitchEvent): string {
  if (event.reason !== 'unknown') return reasonLabel(event.reason);
  if (
    event.on_backup === true &&
    event.primary &&
    event.from === event.primary &&
    event.to !== event.primary
  ) {
    return tr('Переход на резерв', 'Switched to backup');
  }
  if (event.old_level == null || event.new_level == null)
    return reasonLabel(event.reason);
  if (event.new_level < event.old_level)
    return tr('Возврат на более высокий уровень', 'Returned to a higher tier');
  if (event.new_level > event.old_level)
    return tr('Переход на более низкий уровень', 'Switched to a lower tier');
  return tr('Смена узла в одном уровне', 'Changed nodes within a tier');
}

function dateLabel(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) {
    return tr('Неизвестно', 'Unknown');
  }
  const d = new Date(timestamp * 1000);
  return Number.isNaN(d.getTime())
    ? tr('Неизвестно', 'Unknown')
    : d.toLocaleString();
}

function formatIsoTime(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '';
  const d = new Date(timestamp * 1000);
  return Number.isNaN(d.getTime()) ? '' : d.toISOString();
}

export function renderSwitchEvent(event: SwitchEvent) {
  const tagCtx = buildRuntimeTagDisplayContextFromUci();
  const groupDisplay = humanizeRuntimeTag(
    event.group,
    event.group_display_name,
    { context: tagCtx },
  );
  const fromDisplay = event.from
    ? humanizeRuntimeTag(event.from, event.from_display_name, {
        context: tagCtx,
      })
    : '';
  const toDisplay = humanizeRuntimeTag(event.to, event.to_display_name, {
    context: tagCtx,
  });
  const primaryDisplay = event.primary
    ? humanizeRuntimeTag(event.primary, event.primary_display_name, {
        context: tagCtx,
      })
    : '';

  const fromDelay = event.from_delay_ms;
  const toDelay = event.to_delay_ms;
  const delayLabel = (delay: number, time?: string) =>
    `${delay} ${tr('мс', 'ms')}${time ? ` · ${new Date(time).toLocaleString()}` : ''}`;
  const levelLabel = (level?: number) =>
    level != null ? `${tr('уровень', 'tier')} ${level}` : '';
  const details = E('dl', { class: 'tachyon-switch-history__details' });
  const add = (name: string, value?: string) => {
    if (value) details.append(E('dt', {}, name), E('dd', {}, value));
  };
  const sourceLabels: Record<string, string> = {
    legacy_priority: tr(
      'Контроллер Priority (1.x)',
      'Priority controller (1.x)',
    ),
    clash_proxies: 'Clash API /proxies',
    core_failover: 'Core API /tachyon/failover',
  };
  add(tr('Источник', 'Source'), sourceLabels[event.source]);
  if (event.observed) {
    add(tr('Режим', 'Mode'), event.priority ? 'Priority' : 'URLTest');
  }
  add(
    tr('Причина', 'Reason'),
    event.observed && event.reason === 'unknown'
      ? tr(
          'Обнаружено изменение выбранного узла. Точная причина не предоставлена ядром.',
          'The selected node changed. The core did not report the exact reason.',
        )
      : reasonLabel(event.reason),
  );
  if (event.decided_at != null) {
    add(
      tr('Время решения ядра', 'Core decision time'),
      dateLabel(event.decided_at),
    );
  }
  if (event.old_level != null || event.new_level != null) {
    const levels =
      event.old_level != null && event.new_level != null
        ? `${event.old_level} → ${event.new_level}`
        : levelLabel(event.old_level ?? event.new_level);
    add(tr('Уровни Priority', 'Priority tiers'), levels);
  }
  const cached = tr(
    'Задержка из истории или снимка',
    'Delay from history or snapshot',
  );
  const legacy = tr('Задержка из журнала 1.x', 'Delay from the 1.x log');
  if (fromDelay != null) {
    add(
      event.observed ? cached : legacy,
      `${fromDisplay} · ${delayLabel(fromDelay, event.from_delay_at)}`,
    );
  }
  if (toDelay != null) {
    add(
      event.observed ? cached : legacy,
      `${toDisplay} · ${delayLabel(toDelay, event.to_delay_at)}`,
    );
  }
  const quarantined = [
    event.from_quarantined ? fromDisplay : '',
    event.to_quarantined ? toDisplay : '',
  ].filter(Boolean);
  add(
    tr('На карантине по снимку', 'Quarantined in snapshot'),
    quarantined.join(', '),
  );
  if (primaryDisplay) {
    add(tr('Основной узел', 'Primary node'), primaryDisplay);
  }
  if (event.on_backup != null) {
    add(
      tr('Состояние по снимку', 'State in snapshot'),
      event.on_backup
        ? tr('Задействован резерв', 'Backup in use')
        : tr('На основном узле', 'Primary in use'),
    );
  }
  if (event.primary_healthy != null) {
    add(
      tr('Статус проверки основного узла', 'Primary health status'),
      event.primary_healthy
        ? tr('Успешный', 'Healthy')
        : tr('Неуспешный', 'Unhealthy'),
    );
  }
  if (event.primary_failures != null) {
    add(
      tr('Счётчик отказов основного узла', 'Primary failure counter'),
      String(event.primary_failures),
    );
  }
  add(
    tr(
      'Адреса проверок без секретов',
      'Check addresses with sensitive parts removed',
    ),
    event.check_urls?.join(', '),
  );
  if (event.previous_switch_at != null) {
    add(
      tr('Предыдущее событие', 'Previous event'),
      dateLabel(event.previous_switch_at),
    );
  }
  const titleAttr = (display: string, raw: string) =>
    display !== raw && raw ? { title: raw } : {};
  const route = [
    event.from
      ? E('span', titleAttr(fromDisplay, event.from), fromDisplay)
      : null,
    event.from ? E('span', {}, '→') : null,
    E('strong', titleAttr(toDisplay, event.to), toDisplay),
  ].filter((node): node is HTMLElement => node !== null);
  const delays = [fromDelay, toDelay]
    .map((delay) => (delay == null ? '—' : String(delay)))
    .join(event.from ? ' → ' : '');
  const isoTime = formatIsoTime(event.timestamp);
  const showLatency = event.from
    ? fromDelay != null || toDelay != null
    : toDelay != null;
  const delayValueText = event.from
    ? delays
    : toDelay != null
      ? String(toDelay)
      : '';
  return E('details', { class: 'tachyon-switch-history__event' }, [
    E('summary', {}, [
      E('span', { class: 'tachyon-switch-history__meta' }, [
        E(
          'time',
          isoTime ? { dateTime: isoTime } : {},
          dateLabel(event.timestamp),
        ),
        E('span', titleAttr(groupDisplay, event.group), groupDisplay),
      ]),
      E('span', { class: 'tachyon-switch-history__route' }, route),
      E('span', { class: 'tachyon-switch-history__meta' }, [
        E('span', {}, transitionLabel(event)),
        ...(showLatency
          ? [E('span', {}, `${delayValueText} ${tr('мс', 'ms')}`)]
          : []),
      ]),
    ]),
    details,
  ]);
}

export function openSwitchHistory() {
  const title = tr('История переключений', 'Switch history');
  let events: SwitchEvent[] = [];
  const list = E('div', { class: 'tachyon-switch-history__list' });
  const status = E('div', {
    role: 'status',
    class: 'tachyon-switch-history__status',
  });
  const filter = (label: string) =>
    E('select', {
      'aria-label': label,
      change: () => renderList(),
    }) as HTMLSelectElement;
  const group = filter(tr('Группа', 'Group'));
  const reason = filter(tr('Причина', 'Reason'));
  const refresh = E(
    'button',
    {
      type: 'button',
      class: 'tachyon-studio-btn tachyon-studio-btn--ghost',
      click: () => void load(),
    },
    [renderRefreshCwIcon(14), E('span', {}, tr('Обновить', 'Refresh'))],
  ) as HTMLButtonElement;

  function options(
    select: HTMLSelectElement,
    all: string,
    entries: string[],
    label: (value: string) => string,
  ) {
    const selected = select.value;
    select.replaceChildren(
      E('option', { value: '' }, all),
      ...entries.map((value) => E('option', { value }, label(value))),
    );
    select.value = entries.includes(selected) ? selected : '';
  }

  function renderList() {
    const filtered = events.filter(
      (event) =>
        (!group.value || event.group === group.value) &&
        (!reason.value || event.reason === reason.value),
    );
    list.replaceChildren(...filtered.map(renderSwitchEvent));
    status.textContent = filtered.length
      ? ''
      : events.length
        ? tr(
            'Нет событий по выбранным фильтрам',
            'No events match the selected filters',
          )
        : tr(
            'Переключений пока не зарегистрировано',
            'No switches recorded yet',
          );
  }

  async function load() {
    refresh.disabled = group.disabled = reason.disabled = true;
    status.textContent = tr('Загрузка…', 'Loading…');
    list.setAttribute('aria-busy', 'true');
    try {
      const result = await callBaseMethod<{ events: SwitchEvent[] }>(
        Tachyon.AvailableMethods.CLASH_API,
        ['get_switch_history'],
      );
      if (!list.isConnected) return;

      if (!result.success || !Array.isArray(result.data?.events)) {
        status.textContent = tr(
          'История переключений недоступна',
          'Switch history is unavailable',
        );
        return;
      }
      events = result.data.events;
      const tagCtx = buildRuntimeTagDisplayContextFromUci();
      options(
        group,
        tr('Все группы', 'All groups'),
        [...new Set(events.map((event) => event.group))].sort(),
        (value) => {
          const disp = events.find(
            (event) => event.group === value,
          )?.group_display_name;
          return humanizeRuntimeTag(value, disp, { context: tagCtx });
        },
      );
      options(
        reason,
        tr('Все причины', 'All reasons'),
        [...new Set(events.map((event) => event.reason))].sort(),
        reasonLabel,
      );
      renderList();
    } catch (_error) {
      if (list.isConnected) {
        status.textContent = tr(
          'История переключений недоступна',
          'Switch history is unavailable',
        );
      }
    } finally {
      refresh.disabled = false;
      group.disabled = reason.disabled = !events.length;
      list.removeAttribute('aria-busy');
    }
  }

  options(group, tr('Все группы', 'All groups'), [], (value) => value);
  options(reason, tr('Все причины', 'All reasons'), [], reasonLabel);
  ui.showModal(
    title,
    [
      E('div', { class: 'tachyon-switch-history' }, [
        E('div', { class: 'tachyon-switch-history__controls' }, [
          group,
          reason,
          refresh,
        ]),
        status,
        list,
      ]),
    ],
    'cbi-modal',
  );
  void load();
}
