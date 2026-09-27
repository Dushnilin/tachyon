import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
  refreshRuntimeUiState: vi.fn(),
  getCachedRuntimeUiState: vi.fn(),
  subscribeRuntimeUiState: vi.fn(),
  getUiCapabilities: vi.fn(),
  getEngineStatus: vi.fn(),
  getSingBoxStatus: vi.fn(),
}));

vi.mock('../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

vi.mock('../runtimeUiState.service', () => ({
  refreshRuntimeUiState: mocks.refreshRuntimeUiState,
  getCachedRuntimeUiState: mocks.getCachedRuntimeUiState,
  subscribeRuntimeUiState: mocks.subscribeRuntimeUiState,
}));

vi.mock('../../methods/shell', () => ({
  TachyonShellMethods: {
    getUiCapabilities: mocks.getUiCapabilities,
    getEngineStatus: mocks.getEngineStatus,
    getSingBoxStatus: mocks.getSingBoxStatus,
  },
}));

import type { Tachyon } from '../../types';
import {
  runtimeClient,
  RuntimeClient,
  type KnownGoodStatus,
  type RouteExplainResult,
} from '../runtimeClient';

describe('RuntimeClient', () => {
  let client: RuntimeClient;

  beforeEach(() => {
    vi.clearAllMocks();
    client = new RuntimeClient('/usr/bin/tachyon');
  });

  describe('UI State & Capabilities', () => {
    it('delegates getUiState to refreshRuntimeUiState', async () => {
      const mockState = { service: {} } as unknown as Tachyon.UiState;
      mocks.refreshRuntimeUiState.mockResolvedValueOnce(mockState);

      const res = await client.getUiState({ force: true });
      expect(mocks.refreshRuntimeUiState).toHaveBeenCalledWith({ force: true });
      expect(res).toBe(mockState);
    });

    it('delegates getCachedUiState to getCachedRuntimeUiState', () => {
      const mockState = { service: {} } as unknown as Tachyon.UiState;
      mocks.getCachedRuntimeUiState.mockReturnValueOnce(mockState);

      const res = client.getCachedUiState();
      expect(mocks.getCachedRuntimeUiState).toHaveBeenCalled();
      expect(res).toBe(mockState);
    });

    it('delegates subscribeUiState to subscribeRuntimeUiState', () => {
      const unsubscribeFn = vi.fn();
      mocks.subscribeRuntimeUiState.mockReturnValueOnce(unsubscribeFn);

      const listener = vi.fn();
      const unsub = client.subscribeUiState(listener);
      expect(mocks.subscribeRuntimeUiState).toHaveBeenCalledWith(listener);
      expect(unsub).toBe(unsubscribeFn);
    });

    it('queries getUiCapabilities via TachyonShellMethods', async () => {
      const mockCaps = {
        sing_box_extended: 1,
      } as unknown as Tachyon.GetUiCapabilities;
      mocks.getUiCapabilities.mockResolvedValueOnce({
        success: true,
        data: mockCaps,
      });

      const res = await client.getUiCapabilities();
      expect(mocks.getUiCapabilities).toHaveBeenCalled();
      expect(res).toEqual(mockCaps);
    });
  });

  describe('Engine & Sing-box Status', () => {
    it('queries getEngineRuntime', async () => {
      const mockEngineStatus = {
        engine: 'sing-box',
        running: true,
      } as unknown as Tachyon.GetEngineStatus;
      mocks.getEngineStatus.mockResolvedValueOnce({
        success: true,
        data: mockEngineStatus,
      });

      const res = await client.getEngineRuntime();
      expect(mocks.getEngineStatus).toHaveBeenCalled();
      expect(res).toEqual(mockEngineStatus);
    });

    it('queries getSingBoxStatus', async () => {
      const mockSingBox = {
        status: 'running',
        version: '1.9.0',
      } as unknown as Tachyon.GetSingBoxStatus;
      mocks.getSingBoxStatus.mockResolvedValueOnce({
        success: true,
        data: mockSingBox,
      });

      const res = await client.getSingBoxStatus();
      expect(mocks.getSingBoxStatus).toHaveBeenCalled();
      expect(res).toEqual(mockSingBox);
    });
  });

  describe('Last Known Good (LKG)', () => {
    it('queries getKnownGoodStatus', async () => {
      const mockStatus: KnownGoodStatus = {
        has_known_good: true,
        is_active_config_known_good: true,
        manifest: { engine: 'sing-box', promotion_reason: 'auto' },
      };

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockStatus),
        stderr: '',
      });

      const res = await client.getKnownGoodStatus();
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['known_good', '--json'],
        timeout: 10000,
      });
      expect(res).toEqual(mockStatus);
    });

    it('promotes known good with reason', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: '{"success": true}',
        stderr: '',
      });

      const res = await client.promoteKnownGood('manual_test');
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['known_good_promote', 'manual_test'],
        timeout: 10000,
      });
      expect(res).toBe(true);
    });

    it('restores known good rollback with reason', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: '{"success": true}',
        stderr: '',
      });

      const res = await client.rollbackKnownGood('rollback_test');
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['known_good_restore', 'rollback_test'],
        timeout: 15000,
      });
      expect(res).toBe(true);
    });
  });

  describe('Watchdog Escalation & Emergency', () => {
    it('queries getEscalationStatus', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify({ level: 2, level_name: 'RELOAD_SERVICE' }),
        stderr: '',
      });

      const res = await client.getEscalationStatus();
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['escalation_status'],
        timeout: 10000,
      });
      expect(res).toEqual({ level: 2, level_name: 'RELOAD_SERVICE' });
    });

    it('queries getEmergencyStatus', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify({ active: false }),
        stderr: '',
      });

      const res = await client.getEmergencyStatus();
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['emergency_status'],
        timeout: 10000,
      });
      expect(res).toEqual({ active: false });
    });
  });

  describe('DNS Resolution & Route Explain', () => {
    it('resolves domain', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify({
          domain: 'example.com',
          resolved: true,
          addresses: ['93.184.216.34'],
        }),
        stderr: '',
      });

      const res = await client.resolveDomain('example.com');
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['resolve_domain', 'example.com'],
        timeout: 10000,
      });
      expect(res?.resolved).toBe(true);
      expect(res?.addresses).toEqual(['93.184.216.34']);
    });

    it('explains route', async () => {
      const mockExplain: RouteExplainResult = {
        target: 'github.com',
        client: '192.168.1.100',
        port: 443,
        proto: 'tcp',
        action: 'proxy',
        engine: 'sing-box',
        outbound: 'direct',
      };

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockExplain),
        stderr: '',
      });

      const res = await client.explainRoute(
        '192.168.1.100',
        'github.com',
        443,
        'tcp',
      );
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['route_explain', '192.168.1.100', 'github.com', '443', 'tcp'],
        timeout: 10000,
      });
      expect(res).toEqual(mockExplain);
    });
  });

  describe('singleton export', () => {
    it('exports a default runtimeClient instance', () => {
      expect(runtimeClient).toBeInstanceOf(RuntimeClient);
    });
  });
});
