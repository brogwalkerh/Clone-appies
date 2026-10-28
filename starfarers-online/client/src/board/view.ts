/**
 * Board zoom and pan for touch screens (spec §14 phone layout, HANDOFF §8.9a).
 * The SVG keeps drawing in board units; zooming only narrows its `viewBox`.
 * Gestures react to touch pointers only, so mouse and keyboard play on a
 * laptop behave exactly as before. A drag shorter than `TAP_SLOP_PX` is
 * still a tap; a longer one pans and swallows the click that follows.
 */

import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent, type MouseEvent as ReactMouseEvent } from 'react';

export interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}

export const MAX_ZOOM = 6;
/** Finger travel that turns a tap into a pan. */
export const TAP_SLOP_PX = 8;
/** Zoom step of the + / − buttons. */
export const ZOOM_STEP = 1.5;

export function parseBox(viewBox: string): Box {
  const [x = 0, y = 0, w = 1, h = 1] = viewBox.split(/\s+/).map(Number);
  return { x, y, w, h };
}

export function boxString(b: Box): string {
  return `${b.x.toFixed(2)} ${b.y.toFixed(2)} ${b.w.toFixed(2)} ${b.h.toFixed(2)}`;
}

/** Keep the view no larger than the board, no smaller than `1 / MAX_ZOOM` of it, and inside it. */
export function clampView(full: Box, v: Box): Box {
  const ratio = v.h / v.w;
  let w = Math.min(full.w, Math.max(full.w / MAX_ZOOM, v.w));
  let h = w * ratio;
  if (h > full.h) {
    h = full.h;
    w = h / ratio;
  }
  const x = Math.min(full.x + full.w - w, Math.max(full.x, v.x));
  const y = Math.min(full.y + full.h - h, Math.max(full.y, v.y));
  // A view wider than the board on one axis (aspect mismatch) is centred on that axis.
  return { x: w >= full.w ? full.x + (full.w - w) / 2 : x, y: h >= full.h ? full.y + (full.h - h) / 2 : y, w, h };
}

/** Zoom by `factor` (> 1 zooms in) keeping the board point (cx, cy) under the same screen spot. */
export function zoomView(full: Box, v: Box, factor: number, cx: number = v.x + v.w / 2, cy: number = v.y + v.h / 2): Box {
  const w = v.w / factor;
  const h = v.h / factor;
  return clampView(full, { x: cx - ((cx - v.x) * w) / v.w, y: cy - ((cy - v.y) * h) / v.h, w, h });
}

/** How far the view is zoomed in, 1 = the whole board. */
export function zoomOf(full: Box, v: Box): number {
  return Math.max(full.w / v.w, full.h / v.h);
}

/**
 * A view (screen aspect) centred on `target` that shows it plus `pad` where
 * it can, between `minScale` and `2 × minScale` screen px per unit: targets
 * stay finger-sized even when far-flung ones need a pan, and a lone nearby
 * target does not fill the screen. Clamped to the board.
 */
export function focusView(full: Box, target: Box, screen: { w: number; h: number }, minScale: number, pad = 40): Box {
  const aspect = screen.h / screen.w;
  const fits = Math.max(target.w + 2 * pad, (target.h + 2 * pad) / aspect);
  const w = Math.min(screen.w / minScale, Math.max(fits, screen.w / (2 * minScale)));
  const h = w * aspect;
  return clampView(full, { x: target.x + target.w / 2 - w / 2, y: target.y + target.h / 2 - h / 2, w, h });
}

/** Screen px per board unit for a `preserveAspectRatio="xMidYMid meet"` SVG. */
export function screenScale(rect: { width: number; height: number }, v: Box): number {
  return Math.min(rect.width / v.w, rect.height / v.h);
}

interface Gesture {
  pointers: Map<number, { x: number; y: number }>;
  start: { x: number; y: number } | null;
  moved: boolean;
  pinchDist: number | null;
}

export interface BoardView {
  viewBox: string;
  zoom: number;
  svgRef: React.RefObject<SVGSVGElement | null>;
  zoomBy(factor: number): void;
  fit(): void;
  /** Zoom to a board-unit box (touch only): the legal targets after a ship is picked. */
  focus(target: Box): void;
  handlers: {
    onPointerDown(e: ReactPointerEvent<SVGSVGElement>): void;
    onPointerMove(e: ReactPointerEvent<SVGSVGElement>): void;
    onPointerUp(e: ReactPointerEvent<SVGSVGElement>): void;
    onPointerCancel(e: ReactPointerEvent<SVGSVGElement>): void;
    onClickCapture(e: ReactMouseEvent<SVGSVGElement>): void;
  };
}

/** Minimum screen px per board unit when focusing: a highlighted node's hit circle (32 units) is then ≥ 44 px. */
export const FOCUS_SCALE = 44 / 32;

export function useBoardView(fullViewBox: string): BoardView {
  const full = useMemo(() => parseBox(fullViewBox), [fullViewBox]);
  const [view, setView] = useState<Box>(full);
  useEffect(() => setView(full), [full]);
  const svgRef = useRef<SVGSVGElement | null>(null);
  const gesture = useRef<Gesture>({ pointers: new Map(), start: null, moved: false, pinchDist: null });

  const toBoard = useCallback(
    (clientX: number, clientY: number, v: Box) => {
      const rect = svgRef.current?.getBoundingClientRect();
      if (!rect || rect.width === 0) return { x: v.x + v.w / 2, y: v.y + v.h / 2, s: 1 };
      const s = screenScale(rect, v);
      const ox = (rect.width - v.w * s) / 2;
      const oy = (rect.height - v.h * s) / 2;
      return { x: v.x + (clientX - rect.left - ox) / s, y: v.y + (clientY - rect.top - oy) / s, s };
    },
    [],
  );

  const zoomBy = useCallback((factor: number) => setView((v) => zoomView(full, v, factor)), [full]);
  const fit = useCallback(() => setView(full), [full]);
  const focus = useCallback(
    (target: Box) => {
      const rect = svgRef.current?.getBoundingClientRect();
      if (!rect || rect.width === 0) return;
      setView((v) => {
        const next = focusView(full, target, { w: rect.width, h: rect.height }, FOCUS_SCALE);
        // Never zoom out from a closer view the player chose, as long as it still shows the whole target.
        const inside = target.x >= v.x && target.y >= v.y && target.x + target.w <= v.x + v.w && target.y + target.h <= v.y + v.h;
        return inside && v.w <= next.w ? v : next;
      });
    },
    [full],
  );

  const handlers = useMemo<BoardView['handlers']>(() => {
    const g = gesture.current;
    const end = (e: ReactPointerEvent<SVGSVGElement>) => {
      g.pointers.delete(e.pointerId);
      if (g.pointers.size < 2) g.pinchDist = null;
      if (g.pointers.size === 0) g.start = null;
    };
    return {
      onPointerDown(e) {
        if (e.pointerType !== 'touch') return;
        if (g.pointers.size === 0) {
          g.moved = false;
          g.start = { x: e.clientX, y: e.clientY };
        }
        g.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      },
      onPointerMove(e) {
        const prev = g.pointers.get(e.pointerId);
        if (!prev) return;
        const cur = { x: e.clientX, y: e.clientY };
        g.pointers.set(e.pointerId, cur);
        if (g.pointers.size >= 2) {
          const [a, b] = [...g.pointers.values()] as [{ x: number; y: number }, { x: number; y: number }];
          const dist = Math.hypot(a.x - b.x, a.y - b.y);
          if (g.pinchDist !== null && dist > 0) {
            const factor = dist / g.pinchDist;
            const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
            setView((v) => {
              const p = toBoard(mid.x, mid.y, v);
              return zoomView(full, v, factor, p.x, p.y);
            });
          }
          g.pinchDist = dist;
          g.moved = true;
          return;
        }
        if (!g.moved && g.start && Math.hypot(cur.x - g.start.x, cur.y - g.start.y) < TAP_SLOP_PX) return;
        if (!g.moved) {
          g.moved = true;
          // Capture only once it is a pan: capturing a tap would retarget its click to the SVG.
          e.currentTarget.setPointerCapture?.(e.pointerId);
        }
        const dx = cur.x - prev.x;
        const dy = cur.y - prev.y;
        setView((v) => {
          const s = toBoard(0, 0, v).s;
          return clampView(full, { ...v, x: v.x - dx / s, y: v.y - dy / s });
        });
      },
      onPointerUp: end,
      onPointerCancel: end,
      onClickCapture(e) {
        if (!g.moved) return;
        // The click that ends a pan or pinch is not a tap on a node or ship.
        g.moved = false;
        e.stopPropagation();
        e.preventDefault();
      },
    };
  }, [full, toBoard]);

  return { viewBox: boxString(view), zoom: zoomOf(full, view), svgRef, zoomBy, fit, focus, handlers };
}
