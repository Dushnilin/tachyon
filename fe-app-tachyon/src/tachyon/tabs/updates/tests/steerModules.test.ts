import { describe, expect, it } from 'vitest';
import {
  isSteerModule,
  normalizeSteerModules,
  presetForSteerModules,
  STEER_MODULE_PRESETS,
  STEER_MODULES,
  steerModulesUciArgs,
  toggleSteerModule,
  type SteerModule,
} from '../steerModules';

describe('steerModules', () => {
  it('lists every module the backend can install', () => {
    expect([...STEER_MODULES]).toEqual([
      'obfs',
      'tgws',
      'vless',
      'xsteer',
      'proxy',
      'hysteria2',
    ]);
  });

  it('defaults to every module when nothing is configured', () => {
    expect(normalizeSteerModules(undefined)).toEqual([...STEER_MODULES]);
    expect(normalizeSteerModules(null)).toEqual([...STEER_MODULES]);
    expect(normalizeSteerModules('obfs')).toEqual([...STEER_MODULES]);
  });

  it('keeps only known modules and drops duplicates', () => {
    expect(
      normalizeSteerModules(['vless', 'nope', 'obfs', 'vless', 42]),
    ).toEqual(['vless', 'obfs']);
  });

  it('recognizes module names', () => {
    expect(isSteerModule('hysteria2')).toBe(true);
    expect(isSteerModule('extended')).toBe(false);
  });

  it('maps selections to presets and back', () => {
    expect(presetForSteerModules([...STEER_MODULES])).toBe('all');
    expect(presetForSteerModules([...STEER_MODULE_PRESETS.extended])).toBe(
      'extended',
    );
    expect(presetForSteerModules([])).toBe('base');
    expect(presetForSteerModules(['obfs'])).toBe('custom');
    // A subset of a preset must not read as that preset.
    expect(presetForSteerModules(['obfs', 'tgws'])).toBe('custom');
  });

  it('toggles modules back into canonical order', () => {
    const off = toggleSteerModule([...STEER_MODULES], 'xsteer');
    expect(off).not.toContain('xsteer');
    expect(off).toEqual(['obfs', 'tgws', 'vless', 'proxy', 'hysteria2']);
    expect(toggleSteerModule(off, 'xsteer')).toEqual([...STEER_MODULES]);
    expect(toggleSteerModule([], 'proxy')).toEqual(['proxy']);
  });

  it('stores the default by removing the UCI option', () => {
    expect(steerModulesUciArgs([...STEER_MODULES])).toEqual([
      ['-q', 'delete', 'tachyon.settings.steer_modules'],
    ]);
  });

  it('stores any other selection as one string, empty meaning none', () => {
    expect(steerModulesUciArgs([])).toEqual([
      ['set', 'tachyon.settings.steer_modules='],
    ]);
    const selection: SteerModule[] = ['obfs', 'tgws'];
    expect(steerModulesUciArgs(selection)).toEqual([
      ['set', 'tachyon.settings.steer_modules=obfs tgws'],
    ]);
  });

  it('round-trips through the space-separated form the backend reads', () => {
    const selection: SteerModule[] = ['vless', 'hysteria2'];
    const [, arg] = steerModulesUciArgs(selection)[0]!;
    const stored = arg.slice('tachyon.settings.steer_modules='.length);
    expect(stored.split(' ')).toEqual(selection);
  });
});
