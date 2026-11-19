import { DIAGNOSTICS_CHECKS_MAP } from './constants';
import { TachyonShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { tr } from '../../../helpers/i18n';
import { IDiagnosticsChecksItem, store } from '../../../services';

export async function runTachyonCoreCheck() {
  const storeSystemInfo = store?.get()?.diagnosticsSystemInfo;
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.TACHYON_CORE;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const coreChecks = await TachyonShellMethods.checkTachyonCore();

  if (!coreChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Tachyon Core checks failed');
  }

  const data = coreChecks.data;

  const allGood =
    Boolean(data.tachyon_core_installed) &&
    Boolean(data.tachyon_core_version_ok) &&
    Boolean(data.tachyon_core_service_exist) &&
    Boolean(data.tachyon_core_autostart_disabled) &&
    Boolean(data.tachyon_core_process_running) &&
    Boolean(data.tachyon_core_ports_listening);

  const atLeastOneGood =
    Boolean(data.tachyon_core_installed) ||
    Boolean(data.tachyon_core_version_ok) ||
    Boolean(data.tachyon_core_service_exist) ||
    Boolean(data.tachyon_core_autostart_disabled) ||
    Boolean(data.tachyon_core_process_running) ||
    Boolean(data.tachyon_core_ports_listening);

  const { state, description } = getMeta({ atLeastOneGood, allGood });
  const svcData = store?.get()?.servicesInfoWidget?.data;
  const pidInfo =
    data.tachyon_core_process_running && svcData?.tachyonCorePid
      ? `PID ${svcData.tachyonCorePid}${
          typeof svcData.tachyonCoreMemoryMb === 'number' &&
          svcData.tachyonCoreMemoryMb > 0
            ? ` · ${svcData.tachyonCoreMemoryMb.toFixed(1)} MB`
            : ''
        }${svcData.tachyonCoreUptimePretty ? ` · ${svcData.tachyonCoreUptimePretty}` : ''}`
      : data.tachyon_core_process_running
        ? tr('Активен', 'Running')
        : tr('Остановлен', 'Stopped');

  const versionValue =
    data.tachyon_core_version && data.tachyon_core_version !== 'unknown'
      ? data.tachyon_core_version
      : storeSystemInfo?.tachyon_core_version &&
          storeSystemInfo.tachyon_core_version !== 'loading' &&
          storeSystemInfo.tachyon_core_version !== 'unknown'
        ? storeSystemInfo.tachyon_core_version
        : data.tachyon_core_version_ok
          ? 'OK'
          : tr('Несовместима', 'Incompatible');

  const items: Array<IDiagnosticsChecksItem> = [
    {
      state: data.tachyon_core_installed ? 'success' : 'error',
      key: _('Tachyon Core installed'),
      value:
        data.tachyon_core_bin_path ||
        (data.tachyon_core_installed
          ? '/usr/bin/tachyon-core'
          : tr('Не найден', 'Not found')),
    },
    {
      state: data.tachyon_core_version_ok ? 'success' : 'error',
      key: _('Tachyon Core version is compatible'),
      value: versionValue,
    },
    {
      state: data.tachyon_core_service_exist ? 'success' : 'error',
      key: _('Tachyon Core service exist'),
      value:
        data.tachyon_core_init_path ||
        (data.tachyon_core_service_exist
          ? '/etc/init.d/tachyon-core'
          : tr('Отсутствует', 'Missing')),
    },
    {
      state: data.tachyon_core_autostart_disabled ? 'success' : 'error',
      key: _('Tachyon Core autostart disabled'),
      value: data.tachyon_core_autostart_disabled
        ? tr('Управляется Tachyon', 'Managed by Tachyon')
        : tr('Конфликт init.d', 'Init.d conflict'),
    },
    {
      state: data.tachyon_core_process_running ? 'success' : 'error',
      key: _('Tachyon Core process running'),
      value: pidInfo,
    },
    {
      state: data.tachyon_core_ports_listening ? 'success' : 'error',
      key: _('Tachyon Core listening ports'),
      value:
        data.tachyon_core_listen_ports ||
        (data.tachyon_core_ports_listening
          ? '53, 1602, 9090'
          : tr('Не слушает', 'Not listening')),
    },
  ];

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items,
  });

  if (!atLeastOneGood || !data.tachyon_core_process_running) {
    throw new Error('Tachyon Core checks failed');
  }
}
