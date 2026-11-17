import { afterEach, expect, it, vi } from 'vitest';
import type { Tachyon } from '../../types';

const mocks = vi.hoisted(() => ({
  listener: undefined as ((state: Tachyon.UiState) => void) | undefined,
}));
vi.mock('../tab.service', () => ({
  TabServiceInstance: { onChange: vi.fn() },
}));
vi.mock('../tachyonLogWatcher.service', () => ({
  TachyonLogWatcher: { getInstance: () => ({ init: vi.fn(), start: vi.fn() }) },
}));
vi.mock('../runtimeUiState.service', () => ({
  registerRuntimeStateResumeRefresh: vi.fn(),
  startRuntimeUiStatePolling: vi.fn(),
  subscribeRuntimeUiState(listener: (state: Tachyon.UiState) => void) {
    mocks.listener = listener;
  },
}));
import { coreService } from '../core.service';

const publish = (list_update: Tachyon.UiState['list_update']) =>
  mocks.listener?.({ list_update } as Tachyon.UiState);

afterEach(() => vi.unstubAllGlobals());

it('shows one dismissible native warning per failure and removes it after recovery', () => {
  let notice: { id: string; remove: () => void } | undefined;
  const addNotification = vi.fn<
    (title: string, content: unknown, level: string) => unknown
  >(() => {
    notice = {
      id: '',
      remove: vi.fn(() => {
        notice = undefined;
      }),
    };
    return notice;
  });
  vi.stubGlobal('ui', { addNotification });
  vi.stubGlobal('E', (tag: string, attributes: unknown, children: unknown) => ({
    tag,
    attributes,
    children,
  }));
  vi.stubGlobal('document', { querySelector: () => notice });
  coreService();
  const failed = {
    success: false,
    failures: 1,
    timestamp: 100,
    retry_at: 3700,
    auto_update_enabled: true,
  };
  publish(failed);
  expect(addNotification).toHaveBeenCalledTimes(1);
  expect(addNotification.mock.calls[0]?.[2]).toBe('warning');
  expect(JSON.stringify(addNotification.mock.calls[0])).toContain(
    'Previous lists',
  );
  publish(failed);
  expect(addNotification).toHaveBeenCalledTimes(1);
  notice?.remove();
  publish(failed);
  expect(addNotification).toHaveBeenCalledTimes(1); // user dismissal survives polls
  publish({ ...failed, failures: 2, timestamp: 200, retry_at: 7400 });
  expect(addNotification).toHaveBeenCalledTimes(2);
  const remove = notice?.remove;
  publish({ success: true, failures: 0, retry_at: 0 });
  expect(remove).toHaveBeenCalledOnce();
  expect(notice).toBeUndefined();
});
