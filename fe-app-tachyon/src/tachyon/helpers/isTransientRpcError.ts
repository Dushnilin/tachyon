const TRANSIENT_RPC_ERROR_PATTERNS = [
  'no related rpc reply',
  'request aborted',
  'operation was aborted',
  'failed to execute',
  'networkerror',
  'fetch failed',
  'connection refused',
  'connection reset',
  'connection timed out',
  'timeout',
  'bad gateway',
  'service unavailable',
  'ubus error',
  'ipc error',
];

export function isTransientRpcError(message?: string | null) {
  if (!message) {
    return false;
  }

  const normalized = message.toLowerCase();

  return TRANSIENT_RPC_ERROR_PATTERNS.some((pattern) =>
    normalized.includes(pattern),
  );
}
