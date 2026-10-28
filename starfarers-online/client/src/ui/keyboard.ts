/**
 * Keyboard helpers (spec §14, HANDOFF §8.4).
 *
 * Escape policy: one document-level listener walks the registered handlers
 * from the highest priority (most recent first within a priority) and stops at
 * the first that returns `true`. Only things that may be dismissed register:
 * the finished encounter's "Continue" (DIALOG), and on the game screen a build
 * site pick, the selected ship and the error toast (SCREEN). Mandatory
 * decisions (a pending 7 discard / steal, an awaited encounter pick or choice,
 * the trade-station dialog, the round-4 draft) never register, so Escape there
 * at most closes an optional sub-picker (deselects the ship of a space-jump
 * pick) and never skips the decision.
 */

import { useEffect, useRef, type KeyboardEvent } from 'react';

export const ESCAPE_PRIORITY = { SCREEN: 0, DIALOG: 10 } as const;

interface EscapeEntry {
  priority: number;
  order: number;
  handler: { current: () => boolean };
}

const entries = new Set<EscapeEntry>();
let nextOrder = 0;
let listening = false;

function onKeyDown(e: globalThis.KeyboardEvent) {
  if (e.key !== 'Escape' || e.defaultPrevented) return;
  const sorted = [...entries].sort((a, b) => b.priority - a.priority || b.order - a.order);
  for (const entry of sorted) {
    if (entry.handler.current()) {
      e.preventDefault();
      return;
    }
  }
}

/** Register an Escape handler for the component's lifetime; it returns `true` when it handled the key. */
export function useEscape(handler: () => boolean, priority: number = ESCAPE_PRIORITY.SCREEN): void {
  const ref = useRef(handler);
  ref.current = handler;
  useEffect(() => {
    const entry: EscapeEntry = { priority, order: nextOrder++, handler: ref };
    entries.add(entry);
    if (!listening) {
      document.addEventListener('keydown', onKeyDown);
      listening = true;
    }
    return () => {
      entries.delete(entry);
      if (entries.size === 0 && listening) {
        document.removeEventListener('keydown', onKeyDown);
        listening = false;
      }
    };
  }, [priority]);
}

const FOCUSABLE = 'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

function isTyping(el: Element | null): boolean {
  if (!el) return false;
  if (el instanceof HTMLTextAreaElement) return true;
  return el instanceof HTMLInputElement && el.type !== 'range' && el.type !== 'radio' && el.type !== 'checkbox';
}

/**
 * Callback ref for a dialog root (module-level, so React attaches it once per
 * element): focus moves to the dialog's first enabled control when it opens
 * (unless the user is typing in a text field, e.g. the chat) and back to the
 * previously focused element when it closes. If that element is gone, focus
 * falls back to the first action-bar button so keyboard play continues there.
 */
export function focusDialog(el: HTMLElement | null): (() => void) | undefined {
  if (!el) return undefined;
  const active = document.activeElement;
  if (!el.hasAttribute('tabindex')) el.setAttribute('tabindex', '-1');
  if (isTyping(active)) return undefined;
  const previous = active instanceof HTMLElement || active instanceof SVGElement ? active : null;
  const first = el.querySelector<HTMLElement>(FOCUSABLE);
  (first ?? el).focus();
  return () => {
    setTimeout(() => {
      const now = document.activeElement;
      if (now && now !== document.body && now.isConnected) return;
      if (previous?.isConnected && previous !== document.body) previous.focus();
      else focusActionBar();
    }, 0);
  };
}

/** Focus the first enabled action-bar button, or the bar itself; used when the focused control disappeared. */
export function focusActionBar(): void {
  const bar = document.querySelector<HTMLElement>('[data-testid="action-bar"]');
  const target = bar?.querySelector<HTMLElement>('button:not([disabled])') ?? bar;
  target?.focus();
}

/** Enter / Space on a non-button element (an SVG node or ship) does what a click does. */
export function onActivateKey(activate: () => void) {
  return (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar') {
      e.preventDefault();
      e.stopPropagation();
      activate();
    }
  };
}
