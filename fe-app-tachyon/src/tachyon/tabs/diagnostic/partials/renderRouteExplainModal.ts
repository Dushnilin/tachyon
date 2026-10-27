import { renderButton } from '../../../../partials';
import {
  renderCircleCheckBigIcon24,
  renderRotateCcwIcon24,
} from '../../../../icons';
import {
  runtimeClient,
  type RouteExplainResult,
} from '../../../services/runtimeClient';

interface RoutePreset {
  label: string;
  target: string;
  port: number;
  proto: 'tcp' | 'udp';
}

const ROUTE_PRESETS: RoutePreset[] = [
  { label: 'Instagram', target: 'instagram.com', port: 443, proto: 'tcp' },
  { label: 'YouTube', target: 'youtube.com', port: 443, proto: 'tcp' },
  { label: 'Discord Voice', target: 'discord.gg', port: 443, proto: 'udp' },
  { label: 'Telegram', target: 't.me', port: 443, proto: 'tcp' },
  { label: 'Cloudflare IP', target: '1.1.1.1', port: 443, proto: 'tcp' },
];

function getVerdictMeta(verdict: string): {
  label: string;
  badgeStyle: string;
  alertClass: string;
} {
  switch (verdict) {
    case 'proxied':
    case 'proxy':
      return {
        label: _('PROXIED'),
        badgeStyle:
          'background: #28a745; color: #fff; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600;',
        alertClass: 'alert-message success',
      };
    case 'zapret':
    case 'zapret2':
      return {
        label: _('DPI BYPASS (ZAPRET)'),
        badgeStyle:
          'background: #17a2b8; color: #fff; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600;',
        alertClass: 'alert-message info',
      };
    case 'byedpi':
      return {
        label: _('DPI BYPASS (BYEDPI)'),
        badgeStyle:
          'background: #17a2b8; color: #fff; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600;',
        alertClass: 'alert-message info',
      };
    case 'dns':
    case 'custom_dns':
      return {
        label: _('CUSTOM DNS → DIRECT'),
        badgeStyle:
          'background: #17a2b8; color: #fff; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600;',
        alertClass: 'alert-message info',
      };
    case 'hosts':
      return {
        label: _('STATIC HOSTS → DIRECT'),
        badgeStyle:
          'background: #17a2b8; color: #fff; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600;',
        alertClass: 'alert-message info',
      };
    case 'blocked':
    case 'block':
    case 'drop':
      return {
        label: _('BLOCKED'),
        badgeStyle:
          'background: #dc3545; color: #fff; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600;',
        alertClass: 'alert-message warning',
      };
    case 'local':
      return {
        label: _('LOCAL LAN'),
        badgeStyle:
          'background: #6c757d; color: #fff; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600;',
        alertClass: 'alert-message info',
      };
    case 'direct':
    default:
      return {
        label: _('DIRECT (WAN)'),
        badgeStyle:
          'background: #007bff; color: #fff; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600;',
        alertClass: 'alert-message info',
      };
  }
}

function pickLocalizedExplanation(
  explanation: RouteExplainResult['explanation'],
): string {
  if (!explanation) return '';
  if (typeof explanation === 'string') return explanation;
  const isRu =
    typeof document !== 'undefined' &&
    document.documentElement?.lang?.toLowerCase().startsWith('ru');
  if (isRu && explanation.ru) return explanation.ru;
  // Also check if LuCI translated a known string into Cyrillic
  if (/[а-яё]/i.test(_('Available actions')) && explanation.ru) {
    return explanation.ru;
  }
  return explanation.en || explanation.ru || '';
}

export function renderRouteExplainModal(initialTarget = 'instagram.com') {
  let isRunning = false;

  const targetInput = E('input', {
    type: 'text',
    class: 'cbi-input-text',
    value: initialTarget,
    placeholder: _('Domain, URL, or IP (e.g. instagram.com or 1.1.1.1)'),
    style: 'width: 100%; min-width: 200px;',
  }) as HTMLInputElement;

  const clientInput = E('input', {
    type: 'text',
    class: 'cbi-input-text',
    value: '192.168.1.100',
    placeholder: _('Client IP or MAC (e.g. 192.168.1.100)'),
    style: 'width: 100%; min-width: 140px;',
  }) as HTMLInputElement;

  const portInput = E('input', {
    type: 'number',
    class: 'cbi-input-text',
    value: '443',
    min: '1',
    max: '65535',
    style: 'width: 90px;',
  }) as HTMLInputElement;

  const protoSelect = E(
    'select',
    {
      class: 'cbi-input-select',
      style: 'width: 90px;',
    },
    [
      E('option', { value: 'tcp', selected: true }, 'TCP'),
      E('option', { value: 'udp' }, 'UDP'),
    ],
  ) as HTMLSelectElement;

  const statusLabel = E(
    'div',
    {
      style:
        'font-size: 13px; font-weight: 500; margin-bottom: 12px; color: var(--text-color-medium, #6c757d);',
    },
    _(
      'Enter a target domain or IP address to trace how Tachyon routes its traffic across all 7 pipeline stages.',
    ),
  );

  const resultsContainer = E('div', {
    style: 'display: none; margin-bottom: 16px;',
  });

  const renderStageRow = (
    stepNum: number,
    stageTitle: string,
    summaryNode: HTMLElement | string,
    detailsText: string,
    badgeText?: string,
    badgeColor = '#6c757d',
  ) => {
    return E('tr', { class: 'tr cbi-section-table-row' }, [
      E(
        'td',
        {
          class: 'td',
          style: 'width: 36px; text-align: center; font-weight: bold;',
        },
        String(stepNum),
      ),
      E('td', { class: 'td', style: 'width: 180px; font-weight: 600;' }, [
        stageTitle,
      ]),
      E('td', { class: 'td' }, [
        typeof summaryNode === 'string'
          ? E('code', {}, summaryNode)
          : summaryNode,
        detailsText
          ? E(
              'div',
              {
                style:
                  'font-size: 11px; color: var(--text-color-medium, #6c757d); margin-top: 2px;',
              },
              detailsText,
            )
          : E('span'),
      ]),
      E(
        'td',
        { class: 'td', style: 'width: 110px; text-align: center;' },
        badgeText
          ? [
              E(
                'span',
                {
                  class: 'badge',
                  style: `background: ${badgeColor}; color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 11px;`,
                },
                badgeText,
              ),
            ]
          : ['—'],
      ),
    ]);
  };

  const renderReport = (data: RouteExplainResult) => {
    resultsContainer.innerHTML = '';
    if (typeof resultsContainer.replaceChildren === 'function') {
      resultsContainer.replaceChildren();
    }

    if (data.success === false || data.error) {
      resultsContainer.appendChild(
        E(
          'div',
          { class: 'alert-message warning' },
          data.error || _('Route explanation failed.'),
        ),
      );
      resultsContainer.style.display = 'block';
      return;
    }

    const verdictKey = String(data.verdict || data.action || 'direct');
    const verdictMeta = getVerdictMeta(verdictKey);
    const explanationText = pickLocalizedExplanation(data.explanation);
    const query = data.query || {
      client: clientInput.value.trim() || '192.168.1.100',
      target: targetInput.value.trim(),
      port: Number(portInput.value) || 443,
      proto: protoSelect.value || 'tcp',
    };

    const summaryCard = E(
      'div',
      {
        class: verdictMeta.alertClass,
        style: 'margin-bottom: 14px;',
      },
      [
        E(
          'div',
          {
            style:
              'display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; margin-bottom: 6px;',
          },
          [
            E(
              'div',
              { style: 'display: flex; align-items: center; gap: 8px;' },
              [
                E('span', { style: verdictMeta.badgeStyle }, verdictMeta.label),
                E(
                  'b',
                  {},
                  `${query.client} → ${query.target}:${query.port} (${String(query.proto).toUpperCase()})`,
                ),
              ],
            ),
            data.matched_rule
              ? E(
                  'span',
                  { style: 'font-size: 12px;' },
                  `${_('Matched rule')}: ${data.matched_rule.type} (${data.matched_rule.value})`,
                )
              : E('span'),
          ],
        ),
        explanationText
          ? E('div', { style: 'font-size: 12px;' }, explanationText)
          : E('span'),
      ],
    );

    resultsContainer.appendChild(summaryCard);

    const stages = data.stages;
    if (stages) {
      const s1 = stages['1_client_classification'];
      const s2 = stages['2_target_classification'];
      const s3 = stages['3_section_matching'];
      const s4 = stages['4_dns_decision'];
      const s5 = stages['5_nftables_interception'];
      const s6 = stages['6_policy_routing'];
      const s7 = stages['7_engine_outbound'];

      const rows: HTMLElement[] = [];

      if (s1) {
        rows.push(
          renderStageRow(
            1,
            _('Client Classification'),
            `${s1.client}${s1.mac ? ` (${s1.mac})` : ''}`,
            s1.details,
            s1.is_excluded ? _('EXCLUDED') : _('ACTIVE'),
            s1.is_excluded ? '#ffc107' : '#28a745',
          ),
        );
      }

      if (s2) {
        rows.push(
          renderStageRow(
            2,
            _('Target Classification'),
            `${s2.target}:${s2.port} (${String(s2.proto).toUpperCase()})`,
            s2.details,
            String(s2.target_type || 'host').toUpperCase(),
            s2.is_private_ip ? '#6c757d' : '#007bff',
          ),
        );
      }

      if (s3) {
        const secTitle =
          s3.section_label || s3.matched_section || _('Default rule');
        rows.push(
          renderStageRow(
            3,
            _('Section Matching'),
            `${secTitle} — ${s3.rule_type}: ${s3.rule_value}`,
            s3.details,
            String(s3.action || 'direct').toUpperCase(),
            s3.matched_section
              ? s3.action === 'dns' || s3.action === 'hosts'
                ? '#17a2b8'
                : '#28a745'
              : '#6c757d',
          ),
        );
      }

      if (s4) {
        rows.push(
          renderStageRow(
            4,
            _('DNS Resolution'),
            s4.resolver || s4.mode,
            s4.details,
            String(s4.mode || 'direct').toUpperCase(),
            s4.mode === 'fakeip' || s4.mode === 'tachyon_dns'
              ? '#28a745'
              : s4.mode === 'custom_dns' ||
                  s4.mode === 'dns' ||
                  s4.mode === 'hosts'
                ? '#17a2b8'
                : '#6c757d',
          ),
        );
      }

      if (s5) {
        rows.push(
          renderStageRow(
            5,
            _('Firewall (nftables)'),
            `${s5.table} / ${s5.chain} → ${s5.action}`,
            s5.details,
            s5.intercepted ? _('INTERCEPTED') : _('BYPASS'),
            s5.intercepted ? '#28a745' : '#6c757d',
          ),
        );
      }

      if (s6) {
        rows.push(
          renderStageRow(
            6,
            _('Policy Routing'),
            `${_('Table')}: ${s6.table} (${s6.route})`,
            s6.details,
            s6.table.includes('100') || s6.table.includes('tachyon')
              ? _('TPROXY LO')
              : _('MAIN WAN'),
            s6.table.includes('100') || s6.table.includes('tachyon')
              ? '#17a2b8'
              : '#6c757d',
          ),
        );
      }

      if (s7) {
        const outSummary = s7.group_tag
          ? `${s7.engine} → ${s7.group_tag} → ${s7.selected_node}${s7.node_type ? ` (${s7.node_type})` : ''}`
          : `${s7.engine} → ${s7.selected_node}`;
        rows.push(
          renderStageRow(
            7,
            _('Engine Outbound'),
            outSummary,
            s7.details,
            String(s7.node_type || s7.outbound_tag || s7.engine).toUpperCase(),
            s7.engaged === false ? '#6c757d' : '#28a745',
          ),
        );
      }

      const stageTable = E(
        'table',
        {
          class: 'table cbi-section-table',
          style: 'width: 100%; margin-bottom: 8px; font-size: 12px;',
        },
        [
          E('thead', {}, [
            E('tr', { class: 'tr cbi-section-table-titles' }, [
              E('th', { class: 'th', style: 'width: 36px;' }, '#'),
              E('th', { class: 'th', style: 'width: 180px;' }, _('Stage')),
              E('th', { class: 'th' }, _('Decision & Details')),
              E(
                'th',
                { class: 'th', style: 'width: 110px; text-align: center;' },
                _('State'),
              ),
            ]),
          ]),
          E('tbody', {}, rows),
        ],
      );

      resultsContainer.appendChild(stageTable);
    }

    resultsContainer.style.display = 'block';
  };

  let traceBtn: HTMLElement | null = null;

  const runExplain = async () => {
    if (isRunning) return;
    const rawTarget = targetInput.value.trim();
    if (!rawTarget) {
      statusLabel.textContent = _(
        'Please enter a target domain, URL, or IP address.',
      );
      return;
    }

    isRunning = true;
    if (traceBtn) (traceBtn as HTMLButtonElement).disabled = true;
    statusLabel.textContent = _('Tracing routing decision pipeline...');

    try {
      const clientVal = clientInput.value.trim() || '192.168.1.100';
      const portVal = Math.max(
        1,
        Math.min(65535, Number(portInput.value) || 443),
      );
      const protoVal = protoSelect.value || 'tcp';

      const result = await runtimeClient.explainRoute(
        clientVal,
        rawTarget,
        portVal,
        protoVal,
      );

      if (!result) {
        statusLabel.textContent = _('Failed to trace route.');
        resultsContainer.innerHTML = '';
        if (typeof resultsContainer.replaceChildren === 'function') {
          resultsContainer.replaceChildren();
        }
        resultsContainer.appendChild(
          E(
            'div',
            { class: 'alert-message warning' },
            _(
              'Could not execute route explain command. Ensure Tachyon backend is installed properly.',
            ),
          ),
        );
        resultsContainer.style.display = 'block';
      } else {
        statusLabel.textContent = _('Route decision trace completed.');
        renderReport(result);
      }
    } catch (err) {
      statusLabel.textContent = _('An unexpected error occurred.');
      resultsContainer.innerHTML = '';
      if (typeof resultsContainer.replaceChildren === 'function') {
        resultsContainer.replaceChildren();
      }
      resultsContainer.appendChild(
        E(
          'div',
          { class: 'alert-message warning' },
          err instanceof Error ? err.message : String(err),
        ),
      );
      resultsContainer.style.display = 'block';
    } finally {
      isRunning = false;
      if (traceBtn) (traceBtn as HTMLButtonElement).disabled = false;
    }
  };

  targetInput.addEventListener('keydown', (ev: KeyboardEvent) => {
    if (ev.key === 'Enter') {
      ev.preventDefault();
      void runExplain();
    }
  });

  traceBtn = renderButton({
    classNames: ['cbi-button-action'],
    icon: renderCircleCheckBigIcon24,
    text: _('Trace Route'),
    onClick: runExplain,
  });

  const presetButtons = ROUTE_PRESETS.map((preset) =>
    renderButton({
      classNames: ['cbi-button'],
      text: `${preset.label} (${preset.port}/${preset.proto.toUpperCase()})`,
      onClick: () => {
        targetInput.value = preset.target;
        portInput.value = String(preset.port);
        protoSelect.value = preset.proto;
        void runExplain();
      },
    }),
  );

  const formNode = E(
    'div',
    {
      class: 'cbi-section-node',
      style:
        'padding: 12px; margin-bottom: 12px; border-radius: 6px; background: var(--background-color-high, rgba(128,128,128,0.05)); border: 1px solid var(--border-color, rgba(128,128,128,0.15));',
    },
    [
      E(
        'div',
        {
          style:
            'display: grid; grid-template-columns: 1fr 180px 90px 90px auto; gap: 8px; align-items: end;',
        },
        [
          E('div', {}, [
            E(
              'label',
              {
                style:
                  'display: block; font-size: 11px; font-weight: 600; margin-bottom: 4px;',
              },
              _('Target (Domain / IP / URL)'),
            ),
            targetInput,
          ]),
          E('div', {}, [
            E(
              'label',
              {
                style:
                  'display: block; font-size: 11px; font-weight: 600; margin-bottom: 4px;',
              },
              _('Client IP / MAC'),
            ),
            clientInput,
          ]),
          E('div', {}, [
            E(
              'label',
              {
                style:
                  'display: block; font-size: 11px; font-weight: 600; margin-bottom: 4px;',
              },
              _('Port'),
            ),
            portInput,
          ]),
          E('div', {}, [
            E(
              'label',
              {
                style:
                  'display: block; font-size: 11px; font-weight: 600; margin-bottom: 4px;',
              },
              _('Protocol'),
            ),
            protoSelect,
          ]),
          E('div', {}, [traceBtn]),
        ],
      ),
      E(
        'div',
        {
          style:
            'display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin-top: 10px;',
        },
        [
          E(
            'span',
            {
              style:
                'font-size: 11px; color: var(--text-color-medium, #6c757d); margin-right: 4px;',
            },
            _('Quick presets:'),
          ),
          ...presetButtons,
        ],
      ),
    ],
  );

  const modalContent = E('div', { style: 'max-width: 820px; width: 100%;' }, [
    formNode,
    statusLabel,
    resultsContainer,
    E(
      'div',
      {
        class: 'right',
        style:
          'display: flex; justify-content: flex-end; gap: 8px; margin-top: 10px;',
      },
      [
        renderButton({
          classNames: ['cbi-button'],
          icon: renderRotateCcwIcon24,
          text: _('Re-run Trace'),
          onClick: runExplain,
        }),
        renderButton({
          classNames: ['cbi-button-neutral'],
          text: _('Close'),
          onClick: () => ui.hideModal(),
        }),
      ],
    ),
  ]);

  ui.showModal(_('Route Decision Explainer'), modalContent);

  void runExplain();
}
