import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import {
  isJobActive,
  isJobSuccessful,
  isJobTerminal,
  jobClient,
  JobClient,
  type TachyonJob,
} from '../jobClient';

describe('JobClient', () => {
  let client: JobClient;

  beforeEach(() => {
    vi.clearAllMocks();
    client = new JobClient('/usr/bin/tachyon');
  });

  describe('Lifecycle helpers', () => {
    it('correctly identifies active jobs', () => {
      expect(isJobActive({ phase: 'pending' })).toBe(true);
      expect(isJobActive({ phase: 'queued' })).toBe(true);
      expect(isJobActive({ phase: 'running' })).toBe(true);
      expect(isJobActive({ phase: 'verifying' })).toBe(true);
      expect(isJobActive({ phase: 'rollback' })).toBe(true);
      expect(isJobActive({ phase: 'success' })).toBe(false);
      expect(isJobActive({ phase: 'failure' })).toBe(false);
      expect(isJobActive({ phase: 'cancelled' })).toBe(false);
    });

    it('correctly identifies terminal jobs', () => {
      expect(isJobTerminal({ phase: 'running' })).toBe(false);
      expect(isJobTerminal({ phase: 'success' })).toBe(true);
      expect(isJobTerminal({ phase: 'failure' })).toBe(true);
      expect(isJobTerminal({ phase: 'cancelled' })).toBe(true);
      expect(isJobTerminal({ phase: 'timed_out' })).toBe(true);
    });

    it('correctly identifies successful jobs', () => {
      expect(isJobSuccessful({ phase: 'success' })).toBe(true);
      expect(isJobSuccessful({ phase: 'failure' })).toBe(false);
      expect(isJobSuccessful({ phase: 'running' })).toBe(false);
    });
  });

  describe('list', () => {
    it('fetches active jobs', async () => {
      const mockJobs: TachyonJob[] = [
        { id: 'job-1', phase: 'running', action: 'update' },
      ];

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockJobs),
        stderr: '',
      });

      const res = await client.list();
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['job_list', '--json'],
        timeout: 10000,
      });
      expect(res).toEqual(mockJobs);
    });

    it('includes --all flag when requested', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: '[]',
        stderr: '',
      });

      const res = await client.list({ all: true });
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['job_list', '--json', '--all'],
        timeout: 10000,
      });
      expect(res).toEqual([]);
    });

    it('returns empty array on command failure or error', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 1,
        stdout: '',
        stderr: 'error listing jobs',
      });

      const res = await client.list();
      expect(res).toEqual([]);
    });
  });

  describe('query', () => {
    it('returns null if jobId is empty', async () => {
      const res = await client.query('');
      expect(res).toBeNull();
      expect(mocks.executeShellCommand).not.toHaveBeenCalled();
    });

    it('queries single job by ID', async () => {
      const mockJob: TachyonJob = {
        id: 'job-123',
        phase: 'running',
        progress: 50,
      };

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockJob),
        stderr: '',
      });

      const res = await client.query('job-123');
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['job_query', 'job-123'],
        timeout: 10000,
      });
      expect(res).toEqual(mockJob);
    });

    it('returns null if job not found or command exits non-zero', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 1,
        stdout: '{"error": "not found"}',
        stderr: 'Job not found',
      });

      const res = await client.query('non-existent');
      expect(res).toBeNull();
    });
  });

  describe('cancel', () => {
    it('returns error if jobId is missing', async () => {
      const res = await client.cancel('');
      expect(res.ok).toBe(false);
      expect(res.message).toBe('Missing job ID');
    });

    it('calls job_cancel with default options', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify({ ok: true }),
        stderr: '',
      });

      const res = await client.cancel('job-456');
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['job_cancel', 'job-456'],
        timeout: 10000,
      });
      expect(res.ok).toBe(true);
    });

    it('calls job_cancel with --force and reason', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify({ ok: true, forced: true }),
        stderr: '',
      });

      const res = await client.cancel('job-456', {
        force: true,
        reason: 'user_abort',
      });
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['job_cancel', 'job-456', '--force', 'user_abort'],
        timeout: 10000,
      });
      expect(res.forced).toBe(true);
    });
  });

  describe('requestCancel', () => {
    it('returns error if jobId is missing', async () => {
      const res = await client.requestCancel('');
      expect(res.ok).toBe(false);
      expect(res.requested).toBe(false);
    });

    it('calls job_request_cancel', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify({ ok: true, requested: true }),
        stderr: '',
      });

      const res = await client.requestCancel('job-789', 'graceful_stop');
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['job_request_cancel', 'job-789', 'graceful_stop'],
        timeout: 10000,
      });
      expect(res.ok).toBe(true);
      expect(res.requested).toBe(true);
    });
  });

  describe('gc', () => {
    it('calls job_gc and parses removed count', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify({ ok: true, removed: 3 }),
        stderr: '',
      });

      const res = await client.gc();
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['job_gc'],
        timeout: 10000,
      });
      expect(res.ok).toBe(true);
      expect(res.removed).toBe(3);
    });
  });

  describe('watch', () => {
    it('resolves when job reaches terminal state', async () => {
      const progressSpy = vi.fn();

      mocks.executeShellCommand
        .mockResolvedValueOnce({
          code: 0,
          stdout: JSON.stringify({
            id: 'watch-1',
            phase: 'running',
            progress: 25,
          }),
          stderr: '',
        })
        .mockResolvedValueOnce({
          code: 0,
          stdout: JSON.stringify({
            id: 'watch-1',
            phase: 'success',
            progress: 100,
          }),
          stderr: '',
        });

      const finishedJob = await client.watch('watch-1', {
        pollIntervalMs: 10,
        timeoutMs: 1000,
        onProgress: progressSpy,
      });

      expect(finishedJob.phase).toBe('success');
      expect(progressSpy).toHaveBeenCalledTimes(2);
    });

    it('rejects if aborted by AbortSignal', async () => {
      const controller = new AbortController();

      mocks.executeShellCommand.mockResolvedValue({
        code: 0,
        stdout: JSON.stringify({
          id: 'watch-abort',
          phase: 'running',
          progress: 10,
        }),
        stderr: '',
      });

      const watchPromise = client.watch('watch-abort', {
        pollIntervalMs: 50,
        timeoutMs: 1000,
        signal: controller.signal,
      });

      setTimeout(() => controller.abort(), 20);

      await expect(watchPromise).rejects.toThrow('Job watch aborted by caller');
    });

    it('rejects if job not found', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 1,
        stdout: '',
        stderr: 'Job not found',
      });

      await expect(
        client.watch('unknown-job', { pollIntervalMs: 10 }),
      ).rejects.toThrow('Job unknown-job not found');
    });
  });

  describe('singleton export', () => {
    it('exports a default jobClient instance', () => {
      expect(jobClient).toBeInstanceOf(JobClient);
    });
  });
});
