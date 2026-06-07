import { TabServiceInstance } from './tab.service';
import { store } from './store.service';
import { logger } from './logger.service';
import { PodkopLogWatcher } from './podkopLogWatcher.service';
import { LogNotificationDeduper } from './logNotificationDeduper.service';
import { PodkopShellMethods } from '../methods';
import {
  registerRuntimeStateResumeRefresh,
  startRuntimeUiStatePolling,
} from './runtimeUiState.service';

type CoreServiceOptions = {
  waitForLogWatcherStart?: () => Promise<unknown>;
  logWatcherStartDelayMs?: number;
};

const LOG_WATCHER_INTERVAL_MS = 10000;
const LOG_WATCHER_START_DELAY_MS = 5000;

function showLogErrorNotification(line: string) {
  ui.addNotification(
    _('Podkop Plus Error'),
    E('div', {}, line),
    'error',
    'pdk-log-error-notification',
  );
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

  const watcher = PodkopLogWatcher.getInstance();
  const logNotificationDeduper = new LogNotificationDeduper();

  watcher.init(
    async () => {
      const logs = await PodkopShellMethods.checkLogs();

      if (logs.success) {
        return logs.data as string;
      }

      return '';
    },
    {
      intervalMs: LOG_WATCHER_INTERVAL_MS,
      onNewLog: (line) => {
        if (logNotificationDeduper.shouldNotify(line)) {
          showLogErrorNotification(line);
        }
      },
    },
  );

  const startWatcher = () => watcher.start();
  const scheduleStartWatcher = () =>
    window.setTimeout(
      startWatcher,
      options.logWatcherStartDelayMs ?? LOG_WATCHER_START_DELAY_MS,
    );

  if (typeof window !== 'undefined') {
    if (options.waitForLogWatcherStart) {
      Promise.resolve()
        .then(() => options.waitForLogWatcherStart?.())
        .catch(() => null)
        .finally(scheduleStartWatcher);
    } else {
      scheduleStartWatcher();
    }
  } else {
    startWatcher();
  }

  registerRuntimeStateResumeRefresh();
  startRuntimeUiStatePolling();
}
