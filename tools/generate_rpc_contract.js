#!/usr/bin/env node

/**
 * generate_rpc_contract.js
 * Generates TypeScript interfaces, method registry, metadata, and runtime validators
 * from contracts/tachyon-rpc.json into fe-app-tachyon/src/contracts/generated/rpcContract.ts.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const REPO_ROOT = path.resolve(__dirname, '..');
const CONTRACT_PATH = path.join(REPO_ROOT, 'contracts', 'tachyon-rpc.json');
const OUTPUT_DIR = path.join(REPO_ROOT, 'fe-app-tachyon', 'src', 'contracts', 'generated');
const OUTPUT_FILE = path.join(OUTPUT_DIR, 'rpcContract.ts');

function toPascalCase(str) {
  return str
    .replace(/(?:^\w|[A-Z]|\b\w)/g, (letter) => letter.toUpperCase())
    .replace(/[\s\-_]+/g, '');
}

function mapParamType(type, enums) {
  if (enums && Array.isArray(enums) && enums.length > 0) {
    return enums.map((e) => `'${e}'`).join(' | ');
  }
  switch (type) {
    case 'string':
      return 'string';
    case 'number':
      return 'number';
    case 'boolean':
      return 'boolean';
    case 'array':
      return 'unknown[]';
    case 'object':
      return 'Record<string, unknown>';
    default:
      return 'unknown';
  }
}

function mapReturnType(returns) {
  if (!returns) return 'unknown';
  switch (returns.type) {
    case 'string':
      return 'string';
    case 'number':
      return 'number';
    case 'boolean':
      return 'boolean';
    case 'array':
      return 'Record<string, unknown>[]';
    case 'object':
      return 'Record<string, unknown>';
    case 'void':
      return 'void';
    default:
      return 'unknown';
  }
}

function generate() {
  if (!fs.existsSync(CONTRACT_PATH)) {
    console.error(`Error: contract file not found at ${CONTRACT_PATH}`);
    process.exit(1);
  }

  const raw = fs.readFileSync(CONTRACT_PATH, 'utf-8');
  const contract = JSON.parse(raw);

  const lines = [];

  lines.push('/**');
  lines.push(' * AUTO-GENERATED FILE — DO NOT EDIT DIRECTLY');
  lines.push(' * Generated from contracts/tachyon-rpc.json via tools/generate_rpc_contract.js');
  lines.push(` * Contract version: ${contract.version}`);
  lines.push(' */');
  lines.push('');

  // ACL and Category types
  lines.push("export type RpcAclLevel = 'read' | 'write' | 'admin' | 'diagnostic';");
  // Derived from the contract rather than listed here. The hardcoded union was a
  // fourth hand-written copy of the surface, and a category that appeared in
  // tachyon-rpc.json without being added to that line failed the type check
  // instead of the generator noticing.
  const categories = [...new Set(contract.methods.map((m) => m.category))].sort();
  lines.push(
    `export type RpcCategory = ${categories.map((c) => `'${c}'`).join(' | ')};`,
  );
  lines.push('');

  // Method names enum/type
  lines.push('export const TACHYON_RPC_METHODS = [');
  for (const m of contract.methods) {
    lines.push(`  '${m.name}',`);
  }
  lines.push('] as const;');
  lines.push('');
  lines.push('export type TachyonRpcMethodName = (typeof TACHYON_RPC_METHODS)[number];');
  lines.push('');

  // Metadata descriptor interface
  lines.push('export interface RpcParamDescriptor {');
  lines.push('  name: string;');
  lines.push("  type: 'string' | 'number' | 'boolean' | 'object' | 'array';");
  lines.push('  required: boolean;');
  lines.push('  description: string;');
  lines.push('  enum?: string[];');
  lines.push('  default?: unknown;');
  lines.push('}');
  lines.push('');
  lines.push('export interface RpcMethodMetadata {');
  lines.push('  name: TachyonRpcMethodName;');
  lines.push('  cli_command: string;');
  lines.push('  category: RpcCategory;');
  lines.push('  acl: RpcAclLevel;');
  lines.push('  description: string;');
  lines.push('  async: boolean;');
  lines.push('  timeout_ms: number;');
  lines.push('  params: RpcParamDescriptor[];');
  lines.push('}');
  lines.push('');

  // Per-method params and return interfaces
  for (const m of contract.methods) {
    const baseName = toPascalCase(m.name);
    const paramsTypeName = `${baseName}Params`;
    const resultTypeName = `${baseName}Result`;

    // Params interface or type
    lines.push(`/** ${m.description} */`);
    if (!m.params || m.params.length === 0) {
      lines.push(`export type ${paramsTypeName} = Record<string, never>;`);
    } else {
      lines.push(`export interface ${paramsTypeName} {`);
      for (const p of m.params || []) {
        const opt = p.required ? '' : '?';
        const tsType = mapParamType(p.type, p.enum);
        lines.push(`  /** ${p.description} */`);
        lines.push(`  ${p.name}${opt}: ${tsType};`);
      }
      lines.push('}');
    }
    lines.push('');

    // Result type
    lines.push(`export type ${resultTypeName} = ${mapReturnType(m.returns)};`);
    lines.push('');
  }

  // Registry interface
  lines.push('export interface TachyonRpcRegistry {');
  for (const m of contract.methods) {
    const baseName = toPascalCase(m.name);
    lines.push(`  '${m.name}': {`);
    lines.push(`    params: ${baseName}Params;`);
    lines.push(`    result: ${baseName}Result;`);
    lines.push('  };');
  }
  lines.push('}');
  lines.push('');

  // Metadata constant map
  lines.push('export const RPC_METADATA_MAP: Record<TachyonRpcMethodName, RpcMethodMetadata> = {');
  for (const m of contract.methods) {
    lines.push(`  '${m.name}': {`);
    lines.push(`    name: '${m.name}',`);
    lines.push(`    cli_command: '${m.cli_command}',`);
    lines.push(`    category: '${m.category}',`);
    lines.push(`    acl: '${m.acl}',`);
    lines.push(`    description: ${JSON.stringify(m.description)},`);
    lines.push(`    async: ${Boolean(m.async)},`);
    lines.push(`    timeout_ms: ${m.timeout_ms || 10000},`);
    lines.push(`    params: ${JSON.stringify(m.params || [])},`);
    lines.push('  },');
  }
  lines.push('};');
  lines.push('');

  // Runtime Validator
  lines.push('export interface ValidationResult {');
  lines.push('  valid: boolean;');
  lines.push('  errors: string[];');
  lines.push('}');
  lines.push('');
  lines.push('export function validateRpcParams<M extends TachyonRpcMethodName>(');
  lines.push('  method: M,');
  lines.push("  params: unknown = {},");
  lines.push('): ValidationResult {');
  lines.push('  const meta = RPC_METADATA_MAP[method];');
  lines.push('  if (!meta) {');
  lines.push("    return { valid: false, errors: [`Unknown RPC method '${method}'`] };");
  lines.push('  }');
  lines.push('');
  lines.push("  const errors: string[] = [];");
  lines.push("  const pObj = (params && typeof params === 'object') ? (params as Record<string, unknown>) : {};");
  lines.push('');
  lines.push('  for (const p of meta.params) {');
  lines.push('    const val = pObj[p.name];');
  lines.push('    if (p.required && (val === undefined || val === null || val === "")) {');
  lines.push("      errors.push(`Missing required parameter '${p.name}' for RPC '${method}'`);");
  lines.push('      continue;');
  lines.push('    }');
  lines.push('    if (val !== undefined && val !== null) {');
  lines.push('      if (p.type === "string" && typeof val !== "string") {');
  lines.push("        errors.push(`Parameter '${p.name}' must be a string, got ${typeof val}`);");
  lines.push('      } else if (p.type === "number" && typeof val !== "number") {');
  lines.push("        errors.push(`Parameter '${p.name}' must be a number, got ${typeof val}`);");
  lines.push('      } else if (p.type === "boolean" && typeof val !== "boolean") {');
  lines.push("        errors.push(`Parameter '${p.name}' must be a boolean, got ${typeof val}`);");
  lines.push('      } else if (p.type === "array" && !Array.isArray(val)) {');
  lines.push("        errors.push(`Parameter '${p.name}' must be an array`);");
  lines.push('      } else if (p.type === "object" && (typeof val !== "object" || Array.isArray(val))) {');
  lines.push("        errors.push(`Parameter '${p.name}' must be an object`);");
  lines.push('      }');
  lines.push('      if (p.enum && typeof val === "string" && !p.enum.includes(val)) {');
  lines.push("        errors.push(`Parameter '${p.name}' value '${val}' is not in allowed enum: ${p.enum.join(', ')}`);");
  lines.push('      }');
  lines.push('    }');
  lines.push('  }');
  lines.push('');
  lines.push('  return { valid: errors.length === 0, errors };');
  lines.push('}');
  lines.push('');

  // Serialize to CLI args helper
  lines.push('export function serializeRpcCliArgs<M extends TachyonRpcMethodName>(');
  lines.push('  method: M,');
  lines.push("  params: TachyonRpcRegistry[M]['params'],");
  lines.push('): string[] {');
  lines.push('  const meta = RPC_METADATA_MAP[method];');
  lines.push('  if (!meta) return [];');
  lines.push('');
  lines.push('  const args: string[] = [meta.cli_command];');
  lines.push('  const p = params as Record<string, unknown>;');
  lines.push('');
  lines.push('  for (const desc of meta.params) {');
  lines.push('    const val = p[desc.name];');
  lines.push('    if (val === undefined || val === null) {');
  lines.push('      continue;');
  lines.push('    }');
  lines.push('    if (desc.type === "boolean") {');
  lines.push('      if (val === true) {');
  lines.push('        args.push(`--${desc.name}`);');
  lines.push('      }');
  lines.push('    } else if (desc.type === "object") {');
  lines.push('      args.push(JSON.stringify(val));');
  lines.push('    } else {');
  lines.push('      args.push(String(val));');
  lines.push('    }');
  lines.push('  }');
  lines.push('');
  lines.push('  return args;');
  lines.push('}');
  lines.push('');

  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  const outputContent = lines.join('\n');
  fs.writeFileSync(OUTPUT_FILE, outputContent, 'utf-8');
  console.log(`Successfully generated RPC contract with ${contract.methods.length} methods to:`);
  console.log(`  ${OUTPUT_FILE}`);
}

generate();
