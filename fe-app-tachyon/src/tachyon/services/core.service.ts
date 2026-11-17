import { TabServiceInstance } from './tab.service';
import { store } from './store.service';
import { logger } from './logger.service';
import { TachyonLogWatcher } from './tachyonLogWatcher.service';
import {
  getTachyonLogNotification,
  LogNotificationDeduper,
  TachyonLogNotification,
} from './logNotificationDeduper.service';
import { TachyonShellMethods } from '../methods';
import {
  registerRuntimeStateResumeRefresh,
  startRuntimeUiStatePolling,
  subscribeRuntimeUiState,
} from './runtimeUiState.service';
import type { Tachyon } from '../types';

interface CoreServiceOptions {
  waitForLogWatcherStart?: () => Promise<unknown>;
  logWatcherStartDelayMs?: number;
}

const LOG_WATCHER_INTERVAL_MS = 30_000;
const LOG_WATCHER_START_DELAY_MS = 5000;

function componentDisplayName(component: string) {
  const sys = store.get().diagnosticsSystemInfo;
  const isSingBoxFork =
    Boolean(sys?.sing_box_extended || sys?.sing_box_lx || sys?.sing_box_tiny) &&
    !sys?.sing_box_tachyon_core;
  const names: Record<string, string> = {
    tachyon: 'Tachyon',
    sing_box: isSingBoxFork ? 'sing-box' : 'tachyon-core',
    'tachyon-core': 'tachyon-core',
    zapret: 'Zapret',
    zapret2: 'Zapret2',
    byedpi: 'ByeDPI',
    wdtt: 'WDTT',
    olcrtc: 'OlcRTC',
  };

  return names[component] || component;
}

function showLogNotification(notification: TachyonLogNotification) {
  if (notification.kind === 'component-update') {
    const message = _('New version %s is available for %s')
      .replace('%s', notification.version)
      .replace('%s', componentDisplayName(notification.component));

    ui.addNotification(
      _('Component update available'),
      E('div', {}, message),
      'warning',
      'tachyon-component-update-notification',
    );
    return;
  }

  ui.addNotification(
    _('Tachyon Error'),
    E('div', {}, notification.line),
    'error',
    'tachyon-log-error-notification',
  );
}

let lastListUpdateNotice = '';

function showListUpdateWarning(state: Tachyon.UiState) {
  const status = state.list_update;
  // Running updates have success=null; keep the previous warning until settled.
  if (!status || typeof status.success !== 'boolean') {
    return;
  }
  const id = 'tachyon-list-update-warning';
  const stamp = status.success
    ? ''
    : `${status.timestamp}:${status.retry_at}:${status.auto_update_enabled}`;
  // Dismissing a warning must survive polling; a new failure gets a new notice.
  if (stamp === lastListUpdateNotice) {
    return;
  }
  lastListUpdateNotice = stamp;
  document.querySelector(`#${id}`)?.remove();
  if (status.success) {
    return;
  }
  const content = [
    E(
      'p',
      {},
      _(
        'Previous lists are kept where available. Check connectivity and list sources.',
      ),
    ),
  ];
  if (status.auto_update_enabled === false) {
    content.push(
      E(
        'p',
        {},
        _('Automatic updates are disabled. Manual update is still available.'),
      ),
    );
  } else if (status.retry_at) {
    content.push(
      E(
        'p',
        {},
        _('Next automatic attempt after: %s').replace(
          '%s',
          new Date(status.retry_at * 1000).toLocaleString(),
        ),
      ),
    );
  }
  const notice = ui.addNotification(
    _('Remote list update failed'),
    E('div', { role: 'status' }, content),
    'warning',
  );
  notice.id = id;
}

export function coreService(options: CoreServiceOptions = {}) {
  TabServiceInstance.onChange((activeId, tabs) => {
    logger.info('[TAB]', activeId);
    store.set({
      tabService: {
        current: activeId || '',
        all: tabs.map((tab) => tab.id),
      },
    });
  });
  const watcher = TachyonLogWatcher.getInstance();
  const logNotificationDeduper = new LogNotificationDeduper();

  watcher.init(
    async () => {
      const logs = await TachyonShellMethods.checkLogs();

      if (logs.success) {
        return logs.data as string;
      }

      return '';
    },
    {
      intervalMs: LOG_WATCHER_INTERVAL_MS,
      onNewLog: (line) => {
        if (logNotificationDeduper.shouldNotify(line)) {
          const notification = getTachyonLogNotification(line);
          if (notification) {
            showLogNotification(notification);
          }
        }
      },
    },
  );

  const startWatcher = async () => {
    if (options.waitForLogWatcherStart) {
      await Promise.resolve()
        .then(() => options.waitForLogWatcherStart?.())
        .catch((error) => logger.info('[LOG WATCHER]', error));
    }

    watcher.start();
  };
  const scheduleStartWatcher = () =>
    globalThis.setTimeout(() => {
      void startWatcher();
    }, options.logWatcherStartDelayMs ?? LOG_WATCHER_START_DELAY_MS);

  if (globalThis.window === undefined) {
    void startWatcher();
  } else {
    scheduleStartWatcher();
  }

  registerRuntimeStateResumeRefresh();
  subscribeRuntimeUiState(showListUpdateWarning);
  startRuntimeUiStatePolling();
}
