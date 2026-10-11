import { DIAGNOSTICS_CHECKS_MAP } from './constants';
import { TachyonShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { getCheckTitle } from '../helpers/getCheckTitle';
import { IDiagnosticsChecksItem, store } from '../../../services';

export async function runSingBoxCheck() {
  const storeSystemInfo = store?.get()?.diagnosticsSystemInfo;
  const initialIsTachyonCore = Boolean(storeSystemInfo?.sing_box_tachyon_core);
  const initialTitle = initialIsTachyonCore
    ? getCheckTitle('Tachyon Core')
    : DIAGNOSTICS_CHECKS_MAP.SINGBOX.title;

  updateCheckStore({
    order: DIAGNOSTICS_CHECKS_MAP.SINGBOX.order,
    code: DIAGNOSTICS_CHECKS_MAP.SINGBOX.code,
    title: initialTitle,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const singBoxChecks = await TachyonShellMethods.checkSingBox();

  if (!singBoxChecks.success) {
    updateCheckStore({
      order: DIAGNOSTICS_CHECKS_MAP.SINGBOX.order,
      code: DIAGNOSTICS_CHECKS_MAP.SINGBOX.code,
      title: initialTitle,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error(
      `${initialIsTachyonCore ? 'Tachyon Core' : 'Sing-box'} checks failed`,
    );
  }

  const data = singBoxChecks.data;
  const isTachyonCore =
    Boolean(data.sing_box_tachyon_core) || initialIsTachyonCore;
  const coreTitle = isTachyonCore ? 'Tachyon Core' : 'Sing-box';
  const title = isTachyonCore
    ? getCheckTitle('Tachyon Core')
    : DIAGNOSTICS_CHECKS_MAP.SINGBOX.title;

  const allGood =
    Boolean(data.sing_box_installed) &&
    Boolean(data.sing_box_version_ok) &&
    Boolean(data.sing_box_service_exist) &&
    Boolean(data.sing_box_autostart_disabled) &&
    Boolean(data.sing_box_process_running) &&
    Boolean(data.sing_box_ports_listening);

  const atLeastOneGood =
    Boolean(data.sing_box_installed) ||
    Boolean(data.sing_box_version_ok) ||
    Boolean(data.sing_box_service_exist) ||
    Boolean(data.sing_box_autostart_disabled) ||
    Boolean(data.sing_box_process_running) ||
    Boolean(data.sing_box_ports_listening);

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  const items: Array<IDiagnosticsChecksItem> = [
    {
      state: data.sing_box_installed ? 'success' : 'error',
      key: isTachyonCore
        ? _('Tachyon Core installed')
        : _('Sing-box installed'),
      value: '',
    },
    {
      state: data.sing_box_version_ok ? 'success' : 'error',
      key: isTachyonCore
        ? _('Tachyon Core version is compatible')
        : _('Sing-box version is compatible (newer than 1.12.4)'),
      value: '',
    },
    {
      state: data.sing_box_service_exist ? 'success' : 'error',
      key: isTachyonCore
        ? _('Tachyon Core service exist')
        : _('Sing-box service exist'),
      value: '',
    },
    {
      state: data.sing_box_autostart_disabled ? 'success' : 'error',
      key: isTachyonCore
        ? _('Tachyon Core autostart disabled')
        : _('Sing-box autostart disabled'),
      value: '',
    },
    {
      state: data.sing_box_process_running ? 'success' : 'error',
      key: isTachyonCore
        ? _('Tachyon Core process running')
        : _('Sing-box process running'),
      value: '',
    },
    {
      state: data.sing_box_ports_listening ? 'success' : 'error',
      key: isTachyonCore
        ? _('Tachyon Core listening ports')
        : _('Sing-box listening ports'),
      value: '',
    },
  ];

  // certificate_sha256 is an upstream 1.15 field, and the capability check reads
  // the version number. An extended build reports 1.14.x, so the line was
  // permanently amber there and told the user to "upgrade to Extended" while they
  // were already on it. lx sets the same flag and tracks upstream on its own, so
  // there is nothing to act on either. tachyon-core carries the field natively
  // (the backend flags it from the capability model, not from the version
  // number), so the line shows "Supported" there too. Both fork variants drop
  // the line; a stock build below 1.15 still gets the warning, and there it is
  // actionable.
  if (!data.sing_box_extended && !isTachyonCore) {
    items.push({
      state: !data.sing_box_installed
        ? 'error'
        : data.sing_box_cert_pin
          ? 'success'
          : 'warning',
      key: _('TLS certificate pinning (sing-box 1.15+)'),
      value: data.sing_box_cert_pin
        ? _('Supported')
        : _('Ignored (Upgrade to Extended)'),
    });
  }

  updateCheckStore({
    order: DIAGNOSTICS_CHECKS_MAP.SINGBOX.order,
    code: DIAGNOSTICS_CHECKS_MAP.SINGBOX.code,
    title,
    description,
    state,
    items,
  });

  if (!atLeastOneGood || !data.sing_box_process_running) {
    throw new Error(`${coreTitle} checks failed`);
  }
}
