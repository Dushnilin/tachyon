import { beforeEach, describe, expect, it } from 'vitest';
import { applyUiStateToStore } from '../uiState.service';
import { store } from '../store.service';
import { Tachyon } from '../../types';
import {
  clearLocalActionOverlay,
  setLocalComponentAction,
  setLocalLatencyAction,
  setLocalServiceAction,
  setLocalSubscriptionAction,
  setLocalSubscriptionTargetAction,
} from '../localActionOverlay.service';

function createUiState(
  actions: Partial<Tachyon.UiState['actions']> = {},
  capabilities: Partial<Tachyon.UiState['capabilities']> = {},
): Tachyon.UiState {
  return {
    service: {
      tachyon: {
        running: 0,
        enabled: 1,
        status: 'starting',
        dns_configured: 0,
      },
      tachyon_core: {
        running: 0,
        enabled: 1,
        status: 'stopped but enabled',
      },
    },
    capabilities: {
      tachyon_core_tailscale: 1,
      server_inbounds_enabled_count: 0,
      ...capabilities,
    },
    actions: {
      service: [],
      latency: [],
      component: [],
      subscription: [],
      ...actions,
    },
  };
}

describe('applyUiStateToStore', () => {
  beforeEach(() => {
    clearLocalActionOverlay();
    store.reset();
  });

  it('applies service, capability, and running action state before first render', () => {
    applyUiStateToStore(
      createUiState({
        service: [
          {
            success: true,
            running: true,
            kind: 'service',
            action: 'start',
            job_id: 'service-1',
          },
        ],
        subscription: [
          {
            success: true,
            running: true,
            job_id: 'subscription-1',
            section: 'main',
            message: 'Subscription update is running',
          },
        ],
        latency: [
          {
            success: true,
            running: true,
            kind: 'latency',
            latency_type: 'group',
            section: 'main',
            tag: 'AUTO',
            job_id: 'latency-1',
            progress: {
              completed: 2,
              total: 5,
              failed: 1,
            },
          },
        ],
        component: [
          {
            success: true,
            running: true,
            job_id: 'component-1',
            component: 'tachyon-core',
            action: 'install',
            message: 'Install is running',
            current_version: '',
            latest_version: '',
            changed: false,
          },
        ],
      }),
    );

    const state = store.get();

    expect(state.servicesInfoWidget).toMatchObject({
      loading: false,
      failed: false,
      data: {
        tachyonEnabled: 1,
        tachyonRunning: 0,
        tachyonStatus: 'starting',
      },
    });
    expect(state.diagnosticsSystemInfo).toMatchObject({
      providerInfoLoaded: true,
      tachyon_core_tailscale: 1,
      server_inbounds_enabled_count: 0,
    });
    expect(state.diagnosticsActions.start.loading).toBe(true);
    expect(state.sectionsWidget.subscriptionUpdatingSections).toEqual({
      main: true,
    });
    expect(state.sectionsWidget.latencyFetchingSections).toEqual({
      main: true,
    });
    expect(state.sectionsWidget.latencyProgressSections).toEqual({
      main: {
        completed: 2,
        total: 5,
        failed: 1,
      },
    });
    expect(state.updatesActions.tachyonCoreInstall.loading).toBe(true);
  });

  it('clears finished persisted action flags while preserving local enable actions', () => {
    store.set({
      diagnosticsActions: {
        ...store.get().diagnosticsActions,
        start: { loading: true },
        enable: { loading: true },
      },
      sectionsWidget: {
        ...store.get().sectionsWidget,
        subscriptionUpdatingSections: { main: true },
        latencyFetchingSections: { main: true },
        latencyProgressSections: {
          main: {
            completed: 1,
            total: 2,
            failed: 0,
          },
        },
      },
      updatesActions: {
        ...store.get().updatesActions,
        tachyonCoreInstall: { loading: true },
      },
    });

    applyUiStateToStore(createUiState());

    const state = store.get();

    expect(state.diagnosticsActions.start.loading).toBe(false);
    expect(state.diagnosticsActions.enable.loading).toBe(true);
    expect(state.sectionsWidget.subscriptionUpdatingSections).toEqual({});
    expect(state.sectionsWidget.latencyFetchingSections).toEqual({});
    expect(state.sectionsWidget.latencyProgressSections).toEqual({});
    expect(state.updatesActions.tachyonCoreInstall.loading).toBe(false);
  });

  it('keeps locally started actions loading until their owner clears them', () => {
    setLocalComponentAction('tachyonCoreInstall', true);
    setLocalSubscriptionAction('proxy', true);
    setLocalLatencyAction('gemini', true);
    setLocalServiceAction('restart', true);

    applyUiStateToStore(createUiState());

    expect(store.get().updatesActions.tachyonCoreInstall.loading).toBe(true);
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({
      proxy: true,
    });
    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      gemini: true,
    });
    expect(store.get().diagnosticsActions.restart.loading).toBe(true);

    clearLocalActionOverlay();
    applyUiStateToStore(createUiState());

    expect(store.get().updatesActions.tachyonCoreInstall.loading).toBe(false);
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({});
    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({});
    expect(store.get().diagnosticsActions.restart.loading).toBe(false);
  });

  it('preserves local latency progress while waiting for runtime progress', () => {
    setLocalLatencyAction('gemini', true);
    store.set({
      sectionsWidget: {
        ...store.get().sectionsWidget,
        latencyFetchingSections: { gemini: true },
        latencyProgressSections: {
          gemini: {
            completed: 0,
            total: 3,
            failed: 0,
          },
        },
      },
    });

    applyUiStateToStore(createUiState());

    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      gemini: true,
    });
    expect(store.get().sectionsWidget.latencyProgressSections).toEqual({
      gemini: {
        completed: 0,
        total: 3,
        failed: 0,
      },
    });
  });

  it('preserves latency progress for running runtime actions without progress', () => {
    store.set({
      sectionsWidget: {
        ...store.get().sectionsWidget,
        latencyFetchingSections: { main: true },
        latencyProgressSections: {
          main: {
            completed: 2,
            total: 5,
            failed: 0,
          },
        },
      },
    });

    applyUiStateToStore(
      createUiState({
        latency: [
          {
            success: true,
            running: true,
            kind: 'latency',
            latency_type: 'proxy_list',
            section: 'main',
            tag: '["one","two"]',
            job_id: 'latency-1',
          },
        ],
      }),
    );

    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      main: true,
    });
    expect(store.get().sectionsWidget.latencyProgressSections).toEqual({
      main: {
        completed: 2,
        total: 5,
        failed: 0,
      },
    });
  });

  it('maps a running reload action to the restart control', () => {
    applyUiStateToStore(
      createUiState({
        service: [
          {
            success: true,
            running: true,
            kind: 'service',
            action: 'reload',
            job_id: 'service-reload',
          },
        ],
      }),
    );

    expect(store.get().diagnosticsActions.restart.loading).toBe(true);
  });

  it('keeps current tachyon-core version while an install action is running', () => {
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        providerInfoLoaded: true,
        tachyon_core_version: '0.3.10',
        tachyon_core_tailscale: 1,
        server_inbounds_enabled_count: 0,
      },
    });

    applyUiStateToStore(
      createUiState(
        {
          component: [
            {
              success: true,
              running: true,
              job_id: 'tachyon-core-install',
              component: 'tachyon-core',
              action: 'install',
              message: 'Install is running',
              current_version: '',
              latest_version: '',
              changed: false,
            },
          ],
        },
        {
          tachyon_core_tailscale: 0,
          server_inbounds_enabled_count: 2,
        },
      ),
    );

    expect(store.get().diagnosticsSystemInfo).toMatchObject({
      providerInfoLoaded: true,
      tachyon_core_version: '0.3.10',
      tachyon_core_tailscale: 0,
      server_inbounds_enabled_count: 2,
    });
    expect(store.get().updatesActions.tachyonCoreInstall.loading).toBe(true);
  });

  it('marks the running tachyon-core install action without pretending it is installed', () => {
    applyUiStateToStore(
      createUiState(
        {
          component: [
            {
              success: true,
              running: true,
              job_id: 'tachyon-core-install',
              component: 'tachyon-core',
              action: 'install',
              message: 'Install is running',
              current_version: '',
              latest_version: '',
              changed: false,
            },
          ],
        },
        {
          tachyon_core_tailscale: 0,
        },
      ),
    );

    expect(store.get().diagnosticsSystemInfo).toMatchObject({
      tachyon_core_tailscale: 0,
    });
    expect(store.get().updatesActions.tachyonCoreInstall.loading).toBe(true);
  });

  it('tracks single-subscription jobs in subscriptionUpdatingTargets without marking whole section', () => {
    setLocalSubscriptionTargetAction('Main::src_local', true);

    applyUiStateToStore(
      createUiState({
        subscription: [
          {
            success: true,
            running: true,
            job_id: 'rust-sub-Main-1',
            section: 'Main',
            source_selector: '2',
            source_index: '2',
            resolved_target: 'src_b',
          },
        ],
      }),
    );

    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({});
    expect(store.get().sectionsWidget.subscriptionUpdatingTargets).toEqual({
      'Main::2': true,
      'Main::src_b': true,
      'Main::src_local': true,
    });

    clearLocalActionOverlay();
    applyUiStateToStore(createUiState());
    expect(store.get().sectionsWidget.subscriptionUpdatingTargets).toEqual({});
  });
});
