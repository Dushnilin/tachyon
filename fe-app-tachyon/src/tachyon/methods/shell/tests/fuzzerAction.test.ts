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
        engine: 'desync',
        target: 'youtube',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.startFuzzer('desync', 'youtube');
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.job_id).toBe('fuzz_12345');
    }
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['fuzzer_start', 'desync', 'youtube', '', '', ''],
      }),
    );
  });

  it('starts fuzzer with combinatorial mode', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        job_id: 'fuzz_combo_1',
        engine: 'desync',
        target: 'youtube',
        mode: 'combinatorial',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.startFuzzer(
      'desync',
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
          'desync',
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
        engine: 'desync',
        target: 'youtube',
        target_url: 'https://www.youtube.com',
        progress_pct: 100,
        results: [
          {
            id: 'desync_yt_multisplit_midsld',
            name: 'YouTube 4K Multisplit + MidSLD',
            engine: 'desync',
            args: 'desync_mode=multisplit',
            success: true,
            http_code: 200,
            ttfb_ms: 120,
            speed_kbps: 4500,
            score: 180,
            badge: 'Best Match',
          },
        ],
        best_strategy: {
          id: 'desync_yt_multisplit_midsld',
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
      expect(res.data.results[0].badge).toBe('Best Match');
    }
  });

  it('applies winning strategy', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        engine: 'desync',
        applied_to: 'global',
        args: 'desync_mode=multisplit',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.applyFuzzerStrategy(
      'desync',
      'desync_mode=multisplit',
      'global',
    );
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.applied_to).toBe('global');
    }
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['fuzzer_apply', 'desync', 'desync_mode=multisplit', 'global'],
      }),
    );
  });

  it('synthesizes AI strategies', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        engine: 'desync',
        target: 'youtube',
        analysis: 'Transit packet filter blocks SNI on first chunk',
        strategies: [
          {
            id: 'ai_1',
            name: 'AI Strategy 1',
            engine: 'desync',
            args: 'desync_mode=multisplit',
            description: 'AI multisplit',
          },
        ],
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.fuzzerAiSynthesize(
      'desync',
      'youtube',
      '',
      'Rostelecom',
    );
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.analysis).toBe(
        'Transit packet filter blocks SNI on first chunk',
      );
      expect(res.data.strategies).toHaveLength(1);
    }
  });

  it('starts fuzzer with custom_file from AI synthesis', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        job_id: 'fuzz_ai_42',
        engine: 'desync',
        target: 'youtube',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.startFuzzer(
      'desync',
      'youtube',
      '',
      'rule_1',
      '/var/run/tachyon/fuzzer_ai_strategies.json',
      'ai_custom',
    );
    expect(res.success).toBe(true);
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: [
          'fuzzer_start',
          'desync',
          'youtube',
          '',
          'rule_1',
          '/var/run/tachyon/fuzzer_ai_strategies.json',
          'ai_custom',
        ],
      }),
    );
  });

  it('gets fuzzer patterns configuration', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        patterns: {
          desync: {
            modes: ['auto', 'multisplit'],
            split_poses: ['1', 'midsld'],
          },
          custom_strategies: [],
        },
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.getFuzzerPatterns();
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.patterns.desync?.split_poses).toEqual(['1', 'midsld']);
    }
  });

  it('saves fuzzer patterns configuration', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        message: 'Patterns saved successfully',
      }),
      stderr: '',
      code: 0,
    });

    const patternsPayload = {
      desync: { modes: ['auto', 'multisplit'], split_poses: ['1', 'midsld'] },
      custom_strategies: [],
    } as unknown as Parameters<
      typeof TachyonShellMethods.saveFuzzerPatterns
    >[0];

    const res = await TachyonShellMethods.saveFuzzerPatterns(patternsPayload);
    expect(res.success).toBe(true);
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['fuzzer_save_patterns', JSON.stringify(patternsPayload)],
      }),
    );
  });

  it('resets fuzzer patterns configuration', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        message: 'Patterns reset to factory defaults',
        patterns: {
          desync: { modes: ['auto'], split_poses: ['1', 'midsld'] },
        },
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.resetFuzzerPatterns();
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.message).toBe('Patterns reset to factory defaults');
    }
  });

  it('stops running fuzzer', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        message: 'Fuzzer stopped',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.stopFuzzer();
    expect(res.success).toBe(true);
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['fuzzer_stop'],
      }),
    );
  });
});
