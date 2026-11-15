import { describe, expect, it } from 'vitest';

import { describeSameReleaseBuild } from '../sameReleaseBuild';

describe('same-release build description', () => {
  it('shows a truncated transition when both builds are identified', () => {
    expect(
      describeSameReleaseBuild({
        currentSha: 'abc1234def5678',
        latestSha: 'ffff9999aaaa',
      }),
    ).toEqual({ kind: 'sha', text: 'abc1234d → ffff9999' });
  });

  it('shows the single known build when only one side has a sha', () => {
    expect(
      describeSameReleaseBuild({ currentSha: 'abc1234def', latestSha: '' }),
    ).toEqual({ kind: 'sha', text: 'abc1234d' });

    expect(
      describeSameReleaseBuild({ currentSha: null, latestSha: 'ffff9999aaaa' }),
    ).toEqual({ kind: 'sha', text: 'ffff9999' });
  });

  it('falls back when the release carries no sha at all', () => {
    // Releases published before the build stamped a commit SHA are told apart by
    // publish timestamps and asset size, so there is nothing to print here — but
    // the label still has to say something, or it claims an update with no
    // evidence behind it.
    expect(describeSameReleaseBuild({})).toEqual({
      kind: 'fallback',
      text: '',
    });

    expect(
      describeSameReleaseBuild({ currentSha: '', latestSha: null }),
    ).toEqual({ kind: 'fallback', text: '' });
  });
});
