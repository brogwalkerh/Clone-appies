/** The real socket.io-client connection to the same origin (Vite proxies it in dev). */

import type { ClientToServerEvents, ServerToClientEvents } from '@starfarers/shared';
import { io, type Socket } from 'socket.io-client';
import { createRemoteGameStore, type RemoteStore, type SocketLike } from './remoteStore.js';

export function createSocket(url?: string): Socket<ServerToClientEvents, ClientToServerEvents> {
  return io(url ?? '/', { autoConnect: false, transports: ['websocket', 'polling'] });
}

let remote: RemoteStore | null = null;

/** Lazily created singleton so the hot-seat route never opens a socket. */
export function remoteStore(): RemoteStore {
  remote ??= createRemoteGameStore(createSocket() as unknown as SocketLike);
  return remote;
}
