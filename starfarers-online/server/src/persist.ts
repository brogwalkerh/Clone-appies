/**
 * Room persistence (HANDOFF §8.1). `RoomStore` writes a `RoomSnapshot` after
 * every mutation that changes it and reads them all back on boot. The
 * interface is deliberately tiny so a Postgres/Supabase store
 * (`rooms(code primary key, snapshot jsonb, updated_at)`) can replace the
 * file store without touching `RoomStore`.
 */

import { mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import type { RoomSnapshot } from './rooms.js';

export interface RoomPersistence {
  /** Insert or replace the snapshot stored under `snapshot.code`. */
  save(snapshot: RoomSnapshot): Promise<void>;
  /** Forget a room; removing an unknown code is not an error. */
  remove(code: string): Promise<void>;
  /**
   * Every stored room. Snapshots written before `updatedAt` existed may lack
   * it; `RoomStore.restore` falls back to `createdAt`.
   */
  loadAll(): Promise<RoomSnapshot[]>;
}

export type WarnFn = (message: string) => void;

/** Room codes come from `ROOM_CODE_ALPHABET`; anything else never becomes a file name. */
const SAFE_CODE = /^[A-Z0-9]{1,32}$/;

function assertSafeCode(code: string): void {
  if (!SAFE_CODE.test(code)) throw new Error(`Refusing to persist room with unsafe code ${JSON.stringify(code)}`);
}

function isErrno(err: unknown, code: string): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: unknown }).code === code;
}

/** Minimal structural check so a truncated or foreign JSON file is skipped rather than crashing `restore`. */
function looksLikeSnapshot(value: unknown): value is RoomSnapshot {
  if (typeof value !== 'object' || value === null) return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.code === 'string' &&
    typeof v.name === 'string' &&
    typeof v.createdAt === 'number' &&
    typeof v.hostId === 'string' &&
    Array.isArray(v.players) &&
    typeof v.config === 'object' &&
    v.config !== null &&
    typeof v.started === 'boolean' &&
    Array.isArray(v.actions) &&
    Array.isArray(v.messages) &&
    (v.rngState === null || (Array.isArray(v.rngState) && v.rngState.length === 4)) &&
    (v.updatedAt === undefined || typeof v.updatedAt === 'number')
  );
}

/**
 * One JSON file per room, `<dir>/<CODE>.json`. Writes go to a unique temp file
 * in the same directory and are renamed over the target, so a crash mid-write
 * leaves the previous snapshot intact. The directory is created on demand.
 */
export class FileRoomPersistence implements RoomPersistence {
  constructor(
    readonly dir: string,
    private readonly warn: WarnFn = (m) => console.warn(`[persist] ${m}`),
  ) {}

  private fileFor(code: string): string {
    assertSafeCode(code);
    return join(this.dir, `${code}.json`);
  }

  async save(snapshot: RoomSnapshot): Promise<void> {
    const target = this.fileFor(snapshot.code);
    await mkdir(this.dir, { recursive: true });
    const tmp = join(this.dir, `${snapshot.code}.json.${process.pid}.${randomBytes(4).toString('hex')}.tmp`);
    try {
      await writeFile(tmp, JSON.stringify(snapshot), 'utf8');
      await rename(tmp, target);
    } catch (err) {
      await rm(tmp, { force: true }).catch(() => {});
      throw err;
    }
  }

  async remove(code: string): Promise<void> {
    await rm(this.fileFor(code), { force: true });
  }

  async loadAll(): Promise<RoomSnapshot[]> {
    let names: string[];
    try {
      names = await readdir(this.dir);
    } catch (err) {
      if (isErrno(err, 'ENOENT')) return [];
      throw err;
    }
    const out: RoomSnapshot[] = [];
    for (const name of names.sort()) {
      const path = join(this.dir, name);
      if (name.endsWith('.tmp')) {
        // Left behind by a crash between write and rename; the real file (if any) is still intact.
        await rm(path, { force: true }).catch(() => {});
        continue;
      }
      if (!name.endsWith('.json')) continue;
      try {
        const parsed: unknown = JSON.parse(await readFile(path, 'utf8'));
        if (!looksLikeSnapshot(parsed)) throw new Error('not a room snapshot');
        if (`${parsed.code}.json` !== name) throw new Error(`file name does not match room code ${parsed.code}`);
        out.push(parsed);
      } catch (err) {
        this.warn(`skipping ${path}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    return out;
  }
}

/**
 * In-memory persistence. Snapshots are JSON round-tripped on the way in and
 * out (as a real store would), and every call is recorded so tests can use it
 * as a spy.
 */
export class MemoryRoomPersistence implements RoomPersistence {
  readonly rooms = new Map<string, string>();
  readonly saves: string[] = [];
  readonly removes: string[] = [];

  async save(snapshot: RoomSnapshot): Promise<void> {
    this.saves.push(snapshot.code);
    this.rooms.set(snapshot.code, JSON.stringify(snapshot));
  }

  async remove(code: string): Promise<void> {
    this.removes.push(code);
    this.rooms.delete(code);
  }

  async loadAll(): Promise<RoomSnapshot[]> {
    return [...this.rooms.values()].map((json) => JSON.parse(json) as RoomSnapshot);
  }

  get(code: string): RoomSnapshot | undefined {
    const json = this.rooms.get(code);
    return json === undefined ? undefined : (JSON.parse(json) as RoomSnapshot);
  }
}
