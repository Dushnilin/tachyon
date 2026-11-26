import { describe, expect, it } from 'vitest';
import { resolvePriorityLevelBadge } from '../priorityLevelBadge';

describe('resolvePriorityLevelBadge', () => {
  it('replaces duplicate single-server level name with priority index [#N]', () => {
    expect(
      resolvePriorityLevelBadge({
        levelName: 'Server A',
        displayName: 'Server A',
        levelIndex: 0,
      }),
    ).toBe('[#1]');
  });

  it('treats names differing only by country flags and spaces as equal', () => {
    expect(
      resolvePriorityLevelBadge(
        {
          levelName: '🇩🇪  Server A ',
          displayName: 'Server A',
          levelIndex: 1,
        },
        '🇩🇪 Server A',
      ),
    ).toBe('[#2]');
  });

  it('keeps distinct group names unchanged', () => {
    expect(
      resolvePriorityLevelBadge({
        levelName: 'EU Group',
        displayName: 'DE-1',
        levelIndex: 0,
      }),
    ).toBe('[EU Group]');
  });

  it('returns empty string when levelName is empty', () => {
    expect(
      resolvePriorityLevelBadge({
        levelName: '   ',
        displayName: 'DE-1',
        levelIndex: 0,
      }),
    ).toBe('');
  });
});
