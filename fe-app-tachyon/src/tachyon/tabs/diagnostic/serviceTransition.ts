type LoadingActionState = {
  loading: boolean;
};

type DiagnosticServiceActions = {
  restart: LoadingActionState;
  start: LoadingActionState;
  stop: LoadingActionState;
  enable: LoadingActionState;
  disable: LoadingActionState;
};

type ComponentActions = Record<string, LoadingActionState>;

export function isServiceTransitionStatus(status: string) {
  return ['starting', 'stopping', 'restarting', 'reloading'].includes(status);
}

export function getServiceTransition(status: string) {
  return {
    starting: status === 'starting',
    stopping: status === 'stopping',
    restarting: status === 'restarting' || status === 'reloading',
  };
}

export function hasLocalMutatingServiceActionLoading(
  actions: DiagnosticServiceActions,
) {
  return (
    actions.restart.loading ||
    actions.start.loading ||
    actions.stop.loading ||
    actions.enable.loading ||
    actions.disable.loading
  );
}

export function shouldSkipServicesInfoAutoRefresh({
  force,
  localMutatingActionLoading,
}: {
  force: boolean;
  localMutatingActionLoading: boolean;
}) {
  return !force && localMutatingActionLoading;
}

export function shouldResetDiagnosticsChecks({
  resetChecks,
  diagnosticsRunLoading,
}: {
  resetChecks: boolean;
  diagnosticsRunLoading: boolean;
}) {
  return resetChecks && !diagnosticsRunLoading;
}

export function shouldDisableDiagnosticRunAction({
  providerInfoLoaded,
  servicesInfoLoading,
  tachyonRunning,
  mutatingServiceActionLoading,
}: {
  providerInfoLoaded: boolean;
  servicesInfoLoading: boolean;
  tachyonRunning: boolean;
  mutatingServiceActionLoading: boolean;
}) {
  return (
    !providerInfoLoaded ||
    servicesInfoLoading ||
    !tachyonRunning ||
    mutatingServiceActionLoading
  );
}

export function hasComponentActionLoading(actions: ComponentActions) {
  return Object.values(actions).some((action) => action.loading);
}

export function getAvailableActionsDisabledState({
  servicesInfoLoading,
  mutatingServiceActionLoading,
  componentActionLoading,
}: {
  servicesInfoLoading: boolean;
  mutatingServiceActionLoading: boolean;
  componentActionLoading: boolean;
}) {
  return {
    serviceControlsDisabled:
      servicesInfoLoading ||
      mutatingServiceActionLoading ||
      componentActionLoading,
    utilityActionsDisabled:
      mutatingServiceActionLoading || componentActionLoading,
    viewLogsDisabled: false,
  };
}

export function shouldShowRestartAction({
  tachyonRunning,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  tachyonRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  return restartLoading || (tachyonRunning && !startLoading && !stopLoading);
}

export function shouldShowStartAction({
  tachyonRunning,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  tachyonRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  return startLoading || (!restartLoading && !tachyonRunning && !stopLoading);
}

export function shouldShowStopAction({
  tachyonRunning,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  tachyonRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  return stopLoading || restartLoading || (tachyonRunning && !startLoading);
}
