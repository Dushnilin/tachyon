import { describe, expect, it } from 'vitest';
import {
  RPC_METADATA_MAP,
  serializeRpcCliArgs,
  TACHYON_RPC_METHODS,
  validateRpcParams,
} from '../generated/rpcContract';

describe('Tachyon RPC Contract', () => {
  describe('Completeness & Schema Integrity', () => {
    it('defines metadata for all registered methods', () => {
      expect(TACHYON_RPC_METHODS.length).toBeGreaterThanOrEqual(40);

      for (const method of TACHYON_RPC_METHODS) {
        const meta = RPC_METADATA_MAP[method];
        expect(meta).toBeDefined();
        expect(meta.name).toBe(method);
        expect(meta.cli_command).toBeTruthy();
        expect(['read', 'write', 'admin', 'diagnostic']).toContain(meta.acl);
        expect(Array.isArray(meta.params)).toBe(true);
        expect(typeof meta.timeout_ms).toBe('number');
        expect(meta.timeout_ms).toBeGreaterThan(0);
      }
    });

    it('covers all critical categories', () => {
      const categories = new Set(
        Object.values(RPC_METADATA_MAP).map((m) => m.category),
      );
      expect(categories).toContain('system');
      expect(categories).toContain('engine');
      expect(categories).toContain('jobs');
      expect(categories).toContain('events');
      expect(categories).toContain('diagnostics');
      expect(categories).toContain('known_good');
      expect(categories).toContain('updates');
    });
  });

  describe('Runtime Validator (validateRpcParams)', () => {
    it('passes when required parameters are provided', () => {
      const res = validateRpcParams('job_query', { job_id: 'job-123' });
      expect(res.valid).toBe(true);
      expect(res.errors).toHaveLength(0);
    });

    it('fails when required parameters are missing', () => {
      const res = validateRpcParams('job_query', {});
      expect(res.valid).toBe(false);
      expect(res.errors[0]).toContain("Missing required parameter 'job_id'");
    });

    it('fails when parameter has wrong primitive type', () => {
      // route_explain port must be a number
      const res = validateRpcParams('route_explain', {
        client: '192.168.1.1',
        target: 'github.com',
        port: 'not-a-number' as unknown as number,
      });
      expect(res.valid).toBe(false);
      expect(res.errors.some((e) => e.includes('must be a number'))).toBe(true);
    });

    it('validates enum values strictly', () => {
      const validAction = validateRpcParams('service_action_async', {
        action: 'restart',
      });
      expect(validAction.valid).toBe(true);

      const invalidAction = validateRpcParams('service_action_async', {
        action: 'destroy_universe' as unknown as 'restart',
      });
      expect(invalidAction.valid).toBe(false);
      expect(invalidAction.errors[0]).toContain('not in allowed enum');
    });

    it('validates object parameters', () => {
      const validEvent = validateRpcParams('event_record', {
        event: 'test_ev',
        data: { key: 'val' },
        severity: 'info',
      });
      expect(validEvent.valid).toBe(true);

      const invalidEvent = validateRpcParams('event_record', {
        event: 'test_ev',
        data: 'not-an-object' as unknown as Record<string, unknown>,
      });
      expect(invalidEvent.valid).toBe(false);
      expect(
        invalidEvent.errors.some((e) => e.includes('must be an object')),
      ).toBe(true);
    });
  });

  describe('CLI Arguments Serializer (serializeRpcCliArgs)', () => {
    it('serializes zero-arg methods', () => {
      const args = serializeRpcCliArgs('get_status', {});
      expect(args).toEqual(['get_status']);
    });

    it('serializes positional string arguments', () => {
      const args = serializeRpcCliArgs('job_query', { job_id: 'j-42' });
      expect(args).toEqual(['job_query', 'j-42']);
    });

    it('serializes boolean flags with -- prefix', () => {
      const args = serializeRpcCliArgs('job_list', { all: true });
      expect(args).toEqual(['job_list', '--all']);

      const argsWithoutAll = serializeRpcCliArgs('job_list', { all: false });
      expect(argsWithoutAll).toEqual(['job_list']);
    });

    it('serializes object payloads as JSON strings', () => {
      const args = serializeRpcCliArgs('event_query', {
        filter: { severity: 'warn' },
      });
      expect(args).toEqual([
        'event_query',
        JSON.stringify({ severity: 'warn' }),
      ]);
    });

    it('serializes complex diagnostics commands correctly', () => {
      const args = serializeRpcCliArgs('route_explain', {
        client: '192.168.1.100',
        target: 'google.com',
        port: 443,
        proto: 'tcp',
      });
      expect(args).toEqual([
        'route_explain',
        '192.168.1.100',
        'google.com',
        '443',
        'tcp',
      ]);
    });
  });
});
