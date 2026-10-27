/**
 * Minimal static file handler for the built client (`client/dist`): sanitised
 * paths, a few content types, SPA fallback to index.html. Enough for a single
 * process deploy; put a CDN or nginx in front for anything bigger.
 */

import { createReadStream, statSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { extname, join, normalize, resolve, sep } from 'node:path';

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.map': 'application/json',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
};

export function createStaticHandler(root: string): (req: IncomingMessage, res: ServerResponse) => void {
  const base = resolve(root);
  const send = (res: ServerResponse, file: string, status = 200) => {
    const type = TYPES[extname(file)] ?? 'application/octet-stream';
    res.writeHead(status, { 'content-type': type, 'cache-control': file.includes(`${sep}assets${sep}`) ? 'public, max-age=31536000, immutable' : 'no-cache' });
    createReadStream(file).pipe(res);
  };
  return (req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const relative = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, '');
    const target = join(base, relative);
    if (!target.startsWith(base + sep) && target !== base) {
      res.writeHead(403).end();
      return;
    }
    try {
      const st = statSync(target);
      if (st.isFile()) return send(res, target);
    } catch {
      /* fall through to the SPA page */
    }
    try {
      const index = join(base, 'index.html');
      statSync(index);
      send(res, index);
    } catch {
      res.writeHead(404, { 'content-type': 'text/plain' }).end('Client build not found. Run `pnpm --filter @starfarers/client build`.');
    }
  };
}
