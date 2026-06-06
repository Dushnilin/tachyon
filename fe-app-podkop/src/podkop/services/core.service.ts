import { TabServiceInstance } from './tab.service';
import { store } from './store.service';
import { logger } from './logger.service';
import { PodkopLogWatcher } from './podkopLogWatcher.service';
import { LogNotificationDeduper } from './logNotificationDeduper.service';
import { PodkopShellMethods } from '../methods';

type CoreServiceOptions = {
  waitForLogWatcherStart?: () => Promise<unknown>;
  logWatcherStartDelayMs?: number;
};

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
      intervalMs: 3000,
      onNewLog: (line) => {
        if (logNotificationDeduper.shouldNotify(line)) {
          showLogErrorNotification(line);
        }
      },
    },
  );

  const startWatcher = () => watcher.start();

  if (typeof window !== 'undefined') {
    window.setTimeout(() => {
      if (options.waitForLogWatcherStart) {
        Promise.resolve()
          .then(() => options.waitForLogWatcherStart?.())
          .catch(() => null)
          .finally(() =>
            window.setTimeout(
              startWatcher,
              options.logWatcherStartDelayMs ?? 0,
            ),
          );
        return;
      }

      startWatcher();
    }, 0);
  } else {
    startWatcher();
  }
}
