export const STEER_MODULES = [
  'obfs',
  'tgws',
  'vless',
  'xsteer',
  'proxy',
  'hysteria2',
] as const;

export type SteerModule = (typeof STEER_MODULES)[number];

export type SteerModulesPreset = 'all' | 'extended' | 'base';

export const STEER_MODULE_PRESETS: Record<SteerModulesPreset, SteerModule[]> = {
  all: [...STEER_MODULES],
  extended: ['obfs', 'tgws', 'vless', 'xsteer'],
  base: [],
};

export function isSteerModule(value: unknown): value is SteerModule {
  return (STEER_MODULES as readonly unknown[]).includes(value);
}

// The backend defaults an absent option to every module, so a missing field (an
// older backend, nothing configured yet) means the same thing: everything on.
// Unknown names are dropped so a stale option never renders as a phantom box.
export function normalizeSteerModules(raw: unknown): SteerModule[] {
  if (!Array.isArray(raw)) {
    return [...STEER_MODULES];
  }
  const out: SteerModule[] = [];
  for (const value of raw) {
    if (isSteerModule(value) && !out.includes(value)) {
      out.push(value);
    }
  }
  return out;
}

export function presetForSteerModules(
  selection: readonly SteerModule[],
): SteerModulesPreset | 'custom' {
  for (const id of ['all', 'extended', 'base'] as const) {
    const preset = STEER_MODULE_PRESETS[id];
    if (
      preset.length === selection.length &&
      preset.every((module) => selection.includes(module))
    ) {
      return id;
    }
  }
  return 'custom';
}

export function toggleSteerModule(
  selection: readonly SteerModule[],
  module: SteerModule,
): SteerModule[] {
  const next = new Set(selection);
  if (next.has(module)) {
    next.delete(module);
  } else {
    next.add(module);
  }
  return STEER_MODULES.filter((name) => next.has(name));
}

// UCI write for the selection. The default (every module) is stored by removing
// the option so the package keeps owning the default; anything else goes in as
// one whitespace-separated string, "" meaning core with no modules. The option
// must never be a real UCI list: common.list_option splits strings itself, and
// an empty list cannot be expressed as one.
export function steerModulesUciArgs(
  selection: readonly SteerModule[],
): string[][] {
  const isAll =
    selection.length === STEER_MODULES.length &&
    STEER_MODULES.every((module) => selection.includes(module));
  if (isAll) {
    return [['-q', 'delete', 'tachyon.settings.steer_modules']];
  }
  return [
    ['set', `tachyon.settings.steer_modules=${[...selection].join(' ')}`],
  ];
}
