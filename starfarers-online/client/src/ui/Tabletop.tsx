/**
 * Tabletop view (experiment): the whole game screen is laid out once as a
 * fixed-size table (`TABLE_W` × `TABLE_H` CSS px) and shown like a photo of
 * it — scaled to fit, then panned and zoomed. Everything inside stays live DOM,
 * so clicks land where they are drawn at any zoom.
 *
 *   pinch (touch / trackpad) or ctrl + wheel   zoom about the fingers / cursor
 *   wheel                                      pan
 *   drag on anything (past a few px)           pan; the click that ends a drag is swallowed
 *   − / Fit / + buttons, keys - + 0            zoom about the view centre / fit
 *
 * Form controls (inputs, selects, the log slider) keep their own drag.
 */

import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';

export const TABLE_W = 2400;
export const TABLE_H = 1560;
const MAX_ZOOM = 3;
const DRAG_PX = 5;
const BUTTON_STEP = 1.5;

interface View {
  x: number;
  y: number;
  s: number;
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Elements whose own pointer drag must not pan the table. */
function ownsDrag(el: EventTarget | null): boolean {
  return el instanceof Element && el.closest('input, select, textarea, [contenteditable="true"]') !== null;
}

/** Scrollable lists inside the table keep plain wheel scrolling. */
function ownsWheel(el: EventTarget | null): boolean {
  return el instanceof Element && el.closest('.log-list, .chat-list') !== null;
}

export function Tabletop({ children }: { children: ReactNode }) {
  const viewport = useRef<HTMLDivElement>(null);
  const [view, setView] = useState<View>({ x: 0, y: 0, s: 1 });
  const viewRef = useRef(view);
  viewRef.current = view;
  const fitRef = useRef(1);

  const size = () => {
    const r = viewport.current?.getBoundingClientRect();
    return { w: r?.width || TABLE_W, h: r?.height || TABLE_H, left: r?.left ?? 0, top: r?.top ?? 0 };
  };

  /** Keeps at least a margin of the table on screen. */
  const settle = useCallback((v: View): View => {
    const { w, h } = size();
    const s = clamp(v.s, fitRef.current * 0.6, MAX_ZOOM);
    const tw = TABLE_W * s;
    const th = TABLE_H * s;
    const m = 80;
    return { s, x: clamp(v.x, Math.min(m - tw, (w - tw) / 2), Math.max(w - m, (w - tw) / 2)), y: clamp(v.y, Math.min(m - th, (h - th) / 2), Math.max(h - m, (h - th) / 2)) };
  }, []);

  const fit = useCallback(() => {
    const { w, h } = size();
    const s = Math.min(w / TABLE_W, h / TABLE_H);
    fitRef.current = s;
    setView({ s, x: (w - TABLE_W * s) / 2, y: (h - TABLE_H * s) / 2 });
  }, []);

  /** Zoom to scale `s` keeping the viewport point (cx, cy) fixed. */
  const zoomAt = useCallback(
    (s: number, cx: number, cy: number) => {
      const v = viewRef.current;
      const ns = clamp(s, fitRef.current * 0.6, MAX_ZOOM);
      setView(settle({ s: ns, x: cx - ((cx - v.x) * ns) / v.s, y: cy - ((cy - v.y) * ns) / v.s }));
    },
    [settle],
  );
  const zoomCentre = (factor: number) => {
    const { w, h } = size();
    zoomAt(viewRef.current.s * factor, w / 2, h / 2);
  };

  useEffect(() => {
    fit();
    const onResize = () => fit();
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, [fit]);

  // Wheel and Safari's trackpad gestures need non-passive listeners to stop the page from zooming.
  useEffect(() => {
    const el = viewport.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      if (!e.ctrlKey && ownsWheel(e.target)) return;
      e.preventDefault();
      const { left, top } = size();
      const v = viewRef.current;
      if (e.ctrlKey) zoomAt(v.s * Math.exp(-e.deltaY * 0.01), e.clientX - left, e.clientY - top);
      else setView(settle({ ...v, x: v.x - e.deltaX, y: v.y - e.deltaY }));
    };
    let gestureStart = 1;
    const onGestureStart = (e: Event) => {
      e.preventDefault();
      gestureStart = viewRef.current.s;
    };
    const onGestureChange = (e: Event) => {
      e.preventDefault();
      const g = e as Event & { scale: number; clientX: number; clientY: number };
      const { left, top } = size();
      zoomAt(gestureStart * g.scale, g.clientX - left, g.clientY - top);
    };
    el.addEventListener('wheel', onWheel, { passive: false });
    el.addEventListener('gesturestart', onGestureStart);
    el.addEventListener('gesturechange', onGestureChange);
    return () => {
      el.removeEventListener('wheel', onWheel);
      el.removeEventListener('gesturestart', onGestureStart);
      el.removeEventListener('gesturechange', onGestureChange);
    };
  }, [settle, zoomAt]);

  // Pointer drag (pan) and two-finger pinch.
  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const gesture = useRef<{ startX: number; startY: number; view: View; panning: boolean } | null>(null);
  const pinch = useRef<{ dist: number; world: { x: number; y: number }; s: number } | null>(null);
  const swallowClick = useRef(false);

  const local = (e: { clientX: number; clientY: number }) => {
    const { left, top } = size();
    return { x: e.clientX - left, y: e.clientY - top };
  };
  const startPinch = () => {
    const [a, b] = [...pointers.current.values()] as [{ x: number; y: number }, { x: number; y: number }];
    const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
    const v = viewRef.current;
    pinch.current = { dist: Math.hypot(a.x - b.x, a.y - b.y) || 1, world: { x: (mid.x - v.x) / v.s, y: (mid.y - v.y) / v.s }, s: v.s };
    swallowClick.current = true;
  };

  const onPointerDown = (e: React.PointerEvent) => {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    if (ownsDrag(e.target)) return;
    pointers.current.set(e.pointerId, local(e));
    if (pointers.current.size === 2) startPinch();
    else if (pointers.current.size === 1) {
      swallowClick.current = false;
      gesture.current = { startX: e.clientX, startY: e.clientY, view: viewRef.current, panning: false };
    }
  };
  const onPointerMove = (e: React.PointerEvent) => {
    if (!pointers.current.has(e.pointerId)) return;
    pointers.current.set(e.pointerId, local(e));
    if (pinch.current && pointers.current.size >= 2) {
      const [a, b] = [...pointers.current.values()] as [{ x: number; y: number }, { x: number; y: number }];
      const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      const s = clamp((pinch.current.s * Math.hypot(a.x - b.x, a.y - b.y)) / pinch.current.dist, fitRef.current * 0.6, MAX_ZOOM);
      setView(settle({ s, x: mid.x - pinch.current.world.x * s, y: mid.y - pinch.current.world.y * s }));
      return;
    }
    const g = gesture.current;
    if (!g) return;
    const dx = e.clientX - g.startX;
    const dy = e.clientY - g.startY;
    if (!g.panning && Math.hypot(dx, dy) < DRAG_PX) return;
    if (!g.panning) {
      g.panning = true;
      swallowClick.current = true;
      viewport.current?.setPointerCapture?.(e.pointerId);
    }
    setView(settle({ ...g.view, x: g.view.x + dx, y: g.view.y + dy }));
  };
  const onPointerEnd = (e: React.PointerEvent) => {
    pointers.current.delete(e.pointerId);
    if (pointers.current.size < 2) pinch.current = null;
    if (pointers.current.size === 0) gesture.current = null;
    else if (pointers.current.size === 1) {
      // One finger left after a pinch: carry on panning from here without a jump.
      const [p] = [...pointers.current.values()] as [{ x: number; y: number }];
      const { left, top } = size();
      gesture.current = { startX: p.x + left, startY: p.y + top, view: viewRef.current, panning: true };
    }
  };
  const onClickCapture = (e: React.MouseEvent) => {
    if (!swallowClick.current) return;
    swallowClick.current = false;
    e.stopPropagation();
    e.preventDefault();
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (ownsDrag(e.target) || e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === '+' || e.key === '=') zoomCentre(BUTTON_STEP);
      else if (e.key === '-' || e.key === '_') zoomCentre(1 / BUTTON_STEP);
      else if (e.key === '0') fit();
      else return;
      e.preventDefault();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  return (
    <div
      className="tabletop"
      ref={viewport}
      data-testid="tabletop"
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerEnd}
      onPointerCancel={onPointerEnd}
      onClickCapture={onClickCapture}
    >
      <div className="table-world" style={{ width: TABLE_W, height: TABLE_H, transform: `translate(${view.x}px, ${view.y}px) scale(${view.s})` }}>
        {children}
      </div>
      <div className="zoom-controls" onPointerDown={(e) => e.stopPropagation()}>
        <button type="button" aria-label="Zoom out" onClick={() => zoomCentre(1 / BUTTON_STEP)}>
          −
        </button>
        <button type="button" onClick={fit} data-testid="zoom-fit">
          Fit
        </button>
        <button type="button" aria-label="Zoom in" onClick={() => zoomCentre(BUTTON_STEP)}>
          +
        </button>
        <span className="zoom-level">{Math.round(view.s * 100)}%</span>
      </div>
    </div>
  );
}
