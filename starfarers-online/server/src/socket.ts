/**
 * Socket.IO binding (spec §13): maps the protocol events onto `RoomStore`.
 * Every per-player emission goes through `broadcastState`, which redacts the
 * authoritative state once per socket; errors go to the sender only.
 */

import { redactState, type ClientToServerEvents, type JoinReply, type ServerToClientEvents, type Action } from '@starfarers/shared';
import type { Server, Socket } from 'socket.io';
import type { Room, RoomPlayer, RoomStore } from './rooms.js';

interface SocketData {
  roomCode?: string;
  playerId?: string;
}

export type GameServer = Server<ClientToServerEvents, ServerToClientEvents, Record<string, never>, SocketData>;
export type GameSocket = Socket<ClientToServerEvents, ServerToClientEvents, Record<string, never>, SocketData>;

export interface AttachOptions {
  log?: (message: string) => void;
}

export function attachSockets(io: GameServer, store: RoomStore, options: AttachOptions = {}): void {
  const log = options.log ?? (() => {});

  const broadcastLobby = (room: Room) => {
    io.to(room.code).emit('lobby', store.lobbyView(room));
  };

  const broadcastState = (room: Room, action: Action | null) => {
    if (!room.game) return;
    for (const player of room.players) {
      if (!player.socketId) continue;
      io.to(player.socketId).emit('state', {
        state: redactState(room.game, player.id),
        action: action ? store.redactAction(action, player.id) : null,
      });
    }
  };

  const bind = (socket: GameSocket, room: Room, player: RoomPlayer): JoinReply => {
    const previous = store.bindSocket(room, player, socket.id);
    if (previous) {
      // The same player opened a second tab or reconnected: the old socket is told to leave.
      const old = io.sockets.sockets.get(previous);
      if (old) {
        delete old.data.roomCode;
        delete old.data.playerId;
        void old.leave(room.code);
        old.emit('error', { code: 'badToken', message: 'This session was resumed from another connection' });
      }
    }
    socket.data.roomCode = room.code;
    socket.data.playerId = player.id;
    void socket.join(room.code);
    return store.joinReply(room, player);
  };

  const current = (socket: GameSocket): { room: Room; player: RoomPlayer } | null => {
    const code = socket.data.roomCode;
    const id = socket.data.playerId;
    if (!code || !id) return null;
    const room = store.getRoom(code);
    const player = room?.players.find((p) => p.id === id);
    return room && player ? { room, player } : null;
  };

  io.on('connection', (socket) => {
    log(`connect ${socket.id}`);

    socket.on('createRoom', (payload, ack) => {
      const result = store.createRoom(payload?.roomName, payload?.playerName);
      if (!result.ok) return ack(result);
      const reply = bind(socket, result.value.room, result.value.player);
      ack({ ok: true, value: reply });
      broadcastLobby(result.value.room);
      log(`room ${result.value.room.code} created by ${result.value.player.name}`);
    });

    socket.on('joinRoom', (payload, ack) => {
      const result = store.joinRoom(payload?.code, payload?.playerName);
      if (!result.ok) return ack(result);
      const reply = bind(socket, result.value.room, result.value.player);
      ack({ ok: true, value: reply });
      broadcastLobby(result.value.room);
    });

    socket.on('resume', (payload, ack) => {
      const result = store.resume(payload?.roomCode, payload?.playerToken);
      if (!result.ok) return ack(result);
      const reply = bind(socket, result.value.room, result.value.player);
      ack({ ok: true, value: reply });
      broadcastLobby(result.value.room);
      // Others see `connected` flip back on the board state too.
      if (result.value.room.started) broadcastState(result.value.room, null);
    });

    socket.on('startGame', (_payload, ack) => {
      const ctx = current(socket);
      if (!ctx) return ack({ ok: false, error: { code: 'notInRoom', message: 'Join a room first' } });
      const result = store.startGame(ctx.room, ctx.player.id);
      if (!result.ok) return ack(result);
      ack({ ok: true, value: { started: true } });
      broadcastLobby(ctx.room);
      broadcastState(ctx.room, null);
      log(`room ${ctx.room.code} started`);
    });

    socket.on('action', (payload, ack) => {
      const ctx = current(socket);
      if (!ctx) return ack({ ok: false, error: { code: 'notInRoom', message: 'Join a room first' } });
      const result = store.applyAction(ctx.room, ctx.player.id, payload?.action);
      if (!result.ok) {
        socket.emit('error', result.error);
        return ack(result);
      }
      ack({ ok: true, value: { accepted: true } });
      broadcastState(ctx.room, payload.action);
    });

    socket.on('chat', (payload, ack) => {
      const ctx = current(socket);
      if (!ctx) return ack({ ok: false, error: { code: 'notInRoom', message: 'Join a room first' } });
      const result = store.addChat(ctx.room, ctx.player, payload?.text);
      if (!result.ok) return ack(result);
      ack({ ok: true, value: { sent: true } });
      io.to(ctx.room.code).emit('chat', result.value);
    });

    socket.on('disconnect', () => {
      const bound = store.unbindSocket(socket.id);
      log(`disconnect ${socket.id}`);
      if (!bound) return;
      broadcastLobby(bound.room);
      if (bound.room.started) broadcastState(bound.room, null);
    });
  });
}
