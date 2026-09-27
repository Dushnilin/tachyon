import { executeShellCommand } from '../../helpers';
import { TachyonShellMethods } from '../methods/shell';
import type { Tachyon } from '../types';
import { logger } from './logger.service';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
  type RuntimeUiStateListener,
} from './runtimeUiState.service';

export interface KnownGoodManifest {
  promoted_at?: number;
  promoted_at_iso?: string;
  promotion_reason?: string;
  engine?: string;
  sha256?: string;
  [key: string]: unknown;
}

export interface KnownGoodObservation {
  status?: 'observing' | 'healthy' | 'failed' | 'idle';
  reason?: string;
  started_at?: number;
  window_seconds?: number;
  checks_passed?: number;
  all_passed?: boolean;
  [key: string]: unknown;
}

export interface KnownGoodStatus {
  has_known_good: boolean;
  is_active_config_known_good: boolean;
  manifest?: KnownGoodManifest | null;
  observation?: KnownGoodObservation | null;
  history_count?: number;
}

export interface EscalationStatus {
  level: number;
  level_name?: string;
  active: boolean;
  reasons?: string[];
  last_escalation_ts?: number;
  cooldown_remaining?: number;
}

export interface EmergencyStatus {
  active: boolean;
  failsafe_active?: boolean;
  triggered_at?: number;
  reason?: string;
  recovery_attempts?: number;
}

export interface ResolveDomainResult {
  domain: string;
  resolved: boolean;
  addresses?: string[];
  cnames?: string[];
  latency_ms?: number;
  error?: string;
}

export interface RouteExplainResult {
  target: string;
  client?: string;
  port?: number;
  proto?: string;
  action: 'proxy' | 'direct' | 'block' | 'drop' | string;
  engine?: string;
  rule_matched?: string;
  outbound?: string;
  explanation?: string;
}

function parseJsonStdout<T>(stdout: string, fallback: T): T {
  if (!stdout) return fallback;
  try {
    let text = stdout.trim();
    const match = text.match(/(\{[\s\S]*\}|\[[\s\S]*\])/);
    if (match) {
      text = match[0];
    }
    return JSON.parse(text) as T;
  } catch (err) {
    logger.warn('[RUNTIME_CLIENT] Failed to parse JSON stdout:', err);
    return fallback;
  }
}

export class RuntimeClient {
  private readonly binaryPath: string;

  constructor(binaryPath = '/usr/bin/tachyon') {
    this.binaryPath = binaryPath;
  }

  // --- UI State Management ---

  async getUiState(options?: {
    force?: boolean;
  }): Promise<Tachyon.UiState | undefined> {
    return refreshRuntimeUiState(options);
  }

  getCachedUiState(): Tachyon.UiState | undefined {
    return getCachedRuntimeUiState();
  }

  subscribeUiState(listener: RuntimeUiStateListener): () => void {
    return subscribeRuntimeUiState(listener);
  }

  async getUiCapabilities(): Promise<Tachyon.GetUiCapabilities | undefined> {
    try {
      const res = await TachyonShellMethods.getUiCapabilities();
      return res.success ? res.data : undefined;
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] getUiCapabilities error:', err);
      return undefined;
    }
  }

  // --- Engine & Diagnostics ---

  async getEngineRuntime(): Promise<Tachyon.GetEngineStatus | undefined> {
    try {
      const res = await TachyonShellMethods.getEngineStatus();
      return res.success ? res.data : undefined;
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] getEngineRuntime error:', err);
      return undefined;
    }
  }

  async getSingBoxStatus(): Promise<Tachyon.GetSingBoxStatus | undefined> {
    try {
      const res = await TachyonShellMethods.getSingBoxStatus();
      return res.success ? res.data : undefined;
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] getSingBoxStatus error:', err);
      return undefined;
    }
  }

  // --- Last Known Good (LKG) State ---

  async getKnownGoodStatus(): Promise<KnownGoodStatus | null> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['known_good', '--json'],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        logger.error('[RUNTIME_CLIENT] known_good status failed:', res.stderr);
        return null;
      }

      return parseJsonStdout<KnownGoodStatus | null>(res.stdout, null);
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] getKnownGoodStatus error:', err);
      return null;
    }
  }

  async promoteKnownGood(reason = 'ui_manual_bless'): Promise<boolean> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['known_good_promote', reason],
        timeout: 10000,
      });
      return (res.code ?? 0) === 0;
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] promoteKnownGood error:', err);
      return false;
    }
  }

  async rollbackKnownGood(reason = 'ui_manual_rollback'): Promise<boolean> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['known_good_restore', reason],
        timeout: 15000,
      });
      return (res.code ?? 0) === 0;
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] rollbackKnownGood error:', err);
      return false;
    }
  }

  // --- Watchdog Escalation & Emergency ---

  async getEscalationStatus(): Promise<EscalationStatus | null> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['escalation_status'],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        return null;
      }

      return parseJsonStdout<EscalationStatus | null>(res.stdout, null);
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] getEscalationStatus error:', err);
      return null;
    }
  }

  async getEmergencyStatus(): Promise<EmergencyStatus | null> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['emergency_status'],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        return null;
      }

      return parseJsonStdout<EmergencyStatus | null>(res.stdout, null);
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] getEmergencyStatus error:', err);
      return null;
    }
  }

  // --- DNS & Routing Inspection ---

  async resolveDomain(domain: string): Promise<ResolveDomainResult | null> {
    if (!domain) return null;

    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['resolve_domain', domain],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        return {
          domain,
          resolved: false,
          error: res.stderr || 'Resolution failed',
        };
      }

      return parseJsonStdout<ResolveDomainResult>(res.stdout, {
        domain,
        resolved: false,
      });
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] resolveDomain error:', err);
      return {
        domain,
        resolved: false,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  }

  async explainRoute(
    client: string,
    target: string,
    port = 443,
    proto = 'tcp',
  ): Promise<RouteExplainResult | null> {
    if (!target) return null;

    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: [
          'route_explain',
          client || '0.0.0.0',
          target,
          String(port),
          proto,
        ],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        return null;
      }

      return parseJsonStdout<RouteExplainResult | null>(res.stdout, null);
    } catch (err) {
      logger.error('[RUNTIME_CLIENT] explainRoute error:', err);
      return null;
    }
  }
}

export const runtimeClient = new RuntimeClient();
