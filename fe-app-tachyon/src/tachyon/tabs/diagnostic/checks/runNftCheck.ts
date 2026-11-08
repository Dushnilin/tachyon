import { DIAGNOSTICS_CHECKS_MAP } from './constants';
import { RemoteFakeIPMethods, TachyonShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { tr } from '../../../helpers/i18n';

export async function runNftCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.NFT;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  await RemoteFakeIPMethods.getFakeIpCheck();
  await RemoteFakeIPMethods.getIpCheck();

  const nftablesChecks = await TachyonShellMethods.checkNftRules();

  if (!nftablesChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Nftables checks failed');
  }

  const data = nftablesChecks.data;
  if (!data || typeof data !== 'object') {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });
    throw new Error('Nftables checks returned invalid data');
  }

  if ((data as { not_applicable?: number }).not_applicable) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Not applicable for current engine'),
      state: 'skipped',
      items: [],
    });
    return;
  }

  const allGood =
    Boolean(data.table_exist) &&
    Boolean(data.rules_mangle_exist) &&
    Boolean(data.rules_mangle_counters) &&
    Boolean(data.rules_mangle_output_exist) &&
    Boolean(data.rules_mangle_output_counters) &&
    Boolean(data.rules_proxy_exist) &&
    Boolean(data.rules_proxy_counters) &&
    !data.rules_other_mark_exist;

  const atLeastOneGood =
    Boolean(data.table_exist) ||
    Boolean(data.rules_mangle_exist) ||
    Boolean(data.rules_mangle_counters) ||
    Boolean(data.rules_mangle_output_exist) ||
    Boolean(data.rules_mangle_output_counters) ||
    Boolean(data.rules_proxy_exist) ||
    Boolean(data.rules_proxy_counters) ||
    !data.rules_other_mark_exist;

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: data.table_exist ? 'success' : 'error',
        key: _('Table exist'),
        value:
          data.table_name ||
          (data.table_exist
            ? 'inet TachyonTable'
            : tr('Отсутствует', 'Missing')),
      },
      {
        state: data.rules_mangle_exist ? 'success' : 'error',
        key: _('Rules mangle exist'),
        value:
          typeof data.mangle_rules_count === 'number'
            ? `${data.mangle_rules_count} ${tr('правил', 'rules')}`
            : data.rules_mangle_exist
              ? tr('Активны', 'Active')
              : tr('Отсутствуют', 'Missing'),
      },
      {
        state: data.rules_mangle_counters ? 'success' : 'warning',
        key: _('Rules mangle counters'),
        value:
          typeof data.mangle_packets === 'number'
            ? `${data.mangle_packets.toLocaleString()} ${tr('пакетов', 'pkts')}`
            : data.rules_mangle_counters
              ? '> 0 pkts'
              : '0 pkts',
      },
      {
        state: data.rules_mangle_output_exist ? 'success' : 'error',
        key: _('Rules mangle output exist'),
        value:
          typeof data.mangle_output_rules_count === 'number'
            ? `${data.mangle_output_rules_count} ${tr('правил', 'rules')}`
            : data.rules_mangle_output_exist
              ? tr('Активны', 'Active')
              : tr('Отсутствуют', 'Missing'),
      },
      {
        state: data.rules_mangle_output_counters ? 'success' : 'error',
        key: _('Rules mangle output counters'),
        value:
          typeof data.mangle_output_packets === 'number'
            ? `${data.mangle_output_packets.toLocaleString()} ${tr('пакетов', 'pkts')}`
            : data.rules_mangle_output_counters
              ? '> 0 pkts'
              : '0 pkts',
      },
      {
        state: data.rules_proxy_exist ? 'success' : 'error',
        key: _('Rules proxy exist'),
        value:
          typeof data.proxy_rules_count === 'number'
            ? `${data.proxy_rules_count} ${tr('правил', 'rules')}`
            : data.rules_proxy_exist
              ? tr('Активны (TProxy :1602)', 'Active (TProxy :1602)')
              : tr('Отсутствуют', 'Missing'),
      },
      {
        state: data.rules_proxy_counters ? 'success' : 'error',
        key: _('Rules proxy counters'),
        value:
          typeof data.proxy_packets === 'number'
            ? `${data.proxy_packets.toLocaleString()} ${tr('пакетов', 'pkts')}`
            : data.rules_proxy_counters
              ? '> 0 pkts'
              : '0 pkts',
      },
      {
        state: !data.rules_other_mark_exist ? 'success' : 'warning',
        key: !data.rules_other_mark_exist
          ? _('No other marking rules found')
          : _('Additional marking rules found'),
        value: !data.rules_other_mark_exist
          ? tr('Чисто', 'Clean')
          : tr('Внешний fwmark', 'External fwmark'),
      },
    ],
  });

  if (!atLeastOneGood) {
    throw new Error('Nftables checks failed');
  }
}
