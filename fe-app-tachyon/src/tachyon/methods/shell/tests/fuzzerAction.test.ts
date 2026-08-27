import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { TachyonShellMethods } from '../index';

describe('TachyonShellMethods Fuzzer Actions', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('starts fuzzer with specified engine and target', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        job_id: 'fuzz_12345',
        engine: 'zapret2',
        target: 'youtube',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.startFuzzer('zapret2', 'youtube');
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.job_id).toBe('fuzz_12345');
    }
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['fuzzer_start', 'zapret2', 'youtube', '', '', ''],
      }),
    );
  });

  it('starts fuzzer with combinatorial mode', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        job_id: 'fuzz_combo_1',
        engine: 'zapret2',
        target: 'youtube',
        mode: 'combinatorial',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.startFuzzer(
      'zapret2',
      'youtube',
      '',
      '',
      '',
      'combinatorial',
    );
    expect(res.success).toBe(true);
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: [
          'fuzzer_start',
          'zapret2',
          'youtube',
          '',
          '',
          '',
          'combinatorial',
        ],
      }),
    );
  });

  it('gets fuzzer status and results', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        running: false,
        job_id: 'fuzz_12345',
        engine: 'zapret2',
        target: 'youtube',
        target_url: 'https://www.youtube.com',
        progress_pct: 100,
        results: [
          {
            id: 'z2_yt_multisplit_midsld',
            name: 'YouTube 4K Multisplit + MidSLD',
            engine: 'zapret2',
            args: '--dpi-desync=multisplit',
            success: true,
            http_code: 200,
            ttfb_ms: 120,
            speed_kbps: 4500,
            score: 180,
            badge: '🏆 Best Match',
          },
        ],
        best_strategy: {
          id: 'z2_yt_multisplit_midsld',
          score: 180,
        },
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.getFuzzerStatus();
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.running).toBe(false);
      expect(res.data.results).toHaveLength(1);
      expect(res.data.results[0].badge).toBe('🏆 Best Match');
    }
  });

  it('applies winning strategy', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        engine: 'zapret2',
        applied_to: 'global',
        args: '--dpi-desync=multisplit',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.applyFuzzerStrategy(
      'zapret2',
      '--dpi-desync=multisplit',
      'global',
    );
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.applied_to).toBe('global');
    }
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['fuzzer_apply', 'zapret2', '--dpi-desync=multisplit', 'global'],
      }),
    );
  });

  it('synthesizes AI strategies', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        engine: 'zapret2',
        target: 'youtube',
        analysis: 'TSPU blocks SNI on first chunk',
        strategies: [
          {
            id: 'ai_1',
            name: 'AI Strategy 1',
            engine: 'zapret2',
            args: '--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq',
            description: 'AI multisplit',
          },
        ],
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.fuzzerAiSynthesize(
      'zapret2',
      'youtube',
      '',
      'Rostelecom',
    );
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.analysis).toBe('TSPU blocks SNI on first chunk');
      expect(res.data.strategies).toHaveLength(1);
    }
  });
});
