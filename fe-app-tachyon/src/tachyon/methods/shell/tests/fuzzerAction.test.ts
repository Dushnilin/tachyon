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
            badge: 'Best Match',
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
      expect(res.data.results[0].badge).toBe('Best Match');
    }
  });

  it('applies winning strategy to explicit section', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        engine: 'desync',
        applied_to: 'rule_1',
        args: '--mode=fake_split',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.applyFuzzerStrategy(
      'desync',
      '--mode=fake_split',
      'rule_1',
    );
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.applied_to).toBe('rule_1');
    }
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['fuzzer_apply', 'desync', '--mode=fake_split', 'rule_1'],
      }),
    );

    const rejectedEmpty = await TachyonShellMethods.applyFuzzerStrategy(
      'desync',
      '--mode=fake_split',
      '',
    );
    expect(rejectedEmpty.success).toBe(false);
    const rejectedGlobal = await TachyonShellMethods.applyFuzzerStrategy(
      'desync',
      '--mode=fake_split',
      'global',
    );
    expect(rejectedGlobal.success).toBe(false);
    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(1);
  });

  it('passes target when fetching fuzzer strategies', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({ desync: [] }),
      stderr: '',
      code: 0,
    });
    const res = await TachyonShellMethods.getFuzzerStrategies(
      'presets',
      'desync',
      'youtube',
    );
    expect(res.success).toBe(true);
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['fuzzer_strategies', 'presets', 'desync', 'youtube'],
      }),
    );
  });

  it('synthesizes AI strategies', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        engine: 'zapret2',
        target: 'youtube',
        analysis: 'Transit packet filter blocks SNI on first chunk',
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
        engine: 'zapret2',
        target: 'youtube',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.startFuzzer(
      'zapret2',
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
          'zapret2',
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
          zapret2: { splits: ['1', '2', 'midsld'] },
          zapret: { splits: ['1', '2'] },
          byedpi: { splits: ['1'] },
          custom_strategies: [],
        },
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.getFuzzerPatterns();
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.patterns.zapret2.splits).toEqual(['1', '2', 'midsld']);
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
      zapret2: { splits: ['1', '2', 'midsld'] },
      zapret: { splits: ['1'] },
      byedpi: { splits: ['1'] },
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
          zapret2: { splits: ['1', '2', '3', 'midsld'] },
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
