import { logger } from './logger.service';

// eslint-disable-next-line
type Listener = (data: any) => void;
type ErrorListener = (error: Event | string) => void;

class SocketManager {
  private static instance: SocketManager;
  private sockets = new Map<string, WebSocket>();
  private listeners = new Map<string, Set<Listener>>();
  private connected = new Map<string, boolean>();
  private errorListeners = new Map<string, Set<ErrorListener>>();
  private reconnectTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private reconnectAttempts = new Map<string, number>();

  private constructor() {}

  static getInstance(): SocketManager {
    if (!SocketManager.instance) {
      SocketManager.instance = new SocketManager();
    }
    return SocketManager.instance;
  }

  resetAll(): void {
    for (const [url, ws] of this.sockets.entries()) {
      try {
        if (
          ws.readyState === WebSocket.OPEN ||
          ws.readyState === WebSocket.CONNECTING
        ) {
          ws.close();
        }
      } catch (err) {
        logger.error(
          '[SOCKET]',
          `resetAll: failed to close socket ${url}`,
          err,
        );
      }
    }

    for (const timer of this.reconnectTimers.values()) {
      clearTimeout(timer);
    }
    this.reconnectTimers.clear();
    this.reconnectAttempts.clear();

    this.sockets.clear();
    this.listeners.clear();
    this.errorListeners.clear();
    this.connected.clear();
    logger.info('[SOCKET]', 'All connections and state have been reset.');
  }

  private scheduleReconnect(url: string): void {
    if (this.reconnectTimers.has(url)) return;

    const attempts = this.reconnectAttempts.get(url) || 0;
    if (attempts >= 10) {
      logger.error(
        '[SOCKET]',
        `Max reconnect attempts (10) reached for ${url}`,
      );
      return;
    }

    const delay = Math.min(1000 * Math.pow(2, attempts), 30000);
    this.reconnectAttempts.set(url, attempts + 1);

    logger.info(
      '[SOCKET]',
      `Scheduling reconnect to ${url} in ${delay}ms (attempt ${attempts + 1})`,
    );

    const timer = setTimeout(() => {
      this.reconnectTimers.delete(url);
      if (this.sockets.has(url)) {
        logger.info('[SOCKET]', `Attempting reconnect to ${url}`);
        this.sockets.delete(url);
        this.connect(url);
      }
    }, delay);

    this.reconnectTimers.set(url, timer);
  }

  connect(url: string): void {
    if (this.sockets.has(url)) return;

    let ws: WebSocket;

    try {
      ws = new WebSocket(url);
    } catch (err) {
      logger.error(
        '[SOCKET]',
        `failed to construct WebSocket for ${url}:`,
        err,
      );
      this.triggerError(url, err instanceof Event ? err : String(err));
      this.scheduleReconnect(url);
      return;
    }

    this.sockets.set(url, ws);
    this.connected.set(url, false);
    this.listeners.set(url, new Set());
    this.errorListeners.set(url, new Set());

    ws.addEventListener('open', () => {
      this.connected.set(url, true);
      this.reconnectAttempts.set(url, 0);
      logger.info('[SOCKET]', 'Connected to', url);
    });

    ws.addEventListener('message', (event) => {
      const handlers = this.listeners.get(url);
      if (handlers) {
        for (const handler of handlers) {
          try {
            handler(event.data);
          } catch (err) {
            logger.error('[SOCKET]', `Handler error for ${url}:`, err);
          }
        }
      }
    });

    ws.addEventListener('close', () => {
      this.connected.set(url, false);
      logger.warn('[SOCKET]', `Disconnected: ${url}`);
      this.triggerError(url, 'Connection closed');
      if (this.sockets.get(url) === ws) {
        this.scheduleReconnect(url);
      }
    });

    ws.addEventListener('error', (err) => {
      logger.error('[SOCKET]', `Socket error for ${url}:`, err);
      this.triggerError(url, err);
    });
  }

  subscribe(url: string, listener: Listener, onError?: ErrorListener): void {
    if (!this.errorListeners.has(url)) {
      this.errorListeners.set(url, new Set());
    }
    if (onError) {
      this.errorListeners.get(url)?.add(onError);
    }

    if (!this.sockets.has(url)) {
      this.connect(url);
    }

    if (!this.listeners.has(url)) {
      this.listeners.set(url, new Set());
    }
    this.listeners.get(url)?.add(listener);
  }

  unsubscribe(url: string, listener: Listener, onError?: ErrorListener): void {
    this.listeners.get(url)?.delete(listener);
    if (onError) {
      this.errorListeners.get(url)?.delete(onError);
    }
  }

  // eslint-disable-next-line
  send(url: string, data: any): void {
    const ws = this.sockets.get(url);
    if (ws && this.connected.get(url)) {
      ws.send(typeof data === 'string' ? data : JSON.stringify(data));
    } else {
      logger.warn('[SOCKET]', `Cannot send: not connected to ${url}`);
      this.triggerError(url, 'Not connected');
    }
  }

  disconnect(url: string): void {
    const timer = this.reconnectTimers.get(url);
    if (timer) {
      clearTimeout(timer);
      this.reconnectTimers.delete(url);
    }
    this.reconnectAttempts.delete(url);

    const ws = this.sockets.get(url);
    if (ws) {
      ws.close();
      this.sockets.delete(url);
      this.listeners.delete(url);
      this.errorListeners.delete(url);
      this.connected.delete(url);
    }
  }

  disconnectAll(): void {
    for (const url of this.sockets.keys()) {
      this.disconnect(url);
    }
  }

  private triggerError(url: string, err: Event | string): void {
    const handlers = this.errorListeners.get(url);
    if (handlers) {
      for (const cb of handlers) {
        try {
          cb(err);
        } catch (e) {
          logger.error('[SOCKET]', `Error handler threw for ${url}:`, e);
        }
      }
    }
  }
}

export const socket = SocketManager.getInstance();
