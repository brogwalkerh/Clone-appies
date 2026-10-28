/**
 * Media-query hooks for the phone layout (spec §14, HANDOFF §8.9a). jsdom has no
 * `matchMedia`, so every query reads as false there and the tests see the
 * laptop layout unless they stub it.
 */

import { useEffect, useState } from 'react';

/** Phone layout: one column, tabbed panels, bottom-sheet dialogs (styles.css uses the same width). */
export const PHONE_QUERY = '(max-width: 767px)';
/** A finger, not a mouse: highlighted spots take a preview tap before the confirm tap. */
export const COARSE_QUERY = '(pointer: coarse)';

export function matchesMedia(query: string): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  return window.matchMedia(query).matches;
}

export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => matchesMedia(query));
  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const mq = window.matchMedia(query);
    const onChange = () => setMatches(mq.matches);
    onChange();
    mq.addEventListener?.('change', onChange);
    return () => mq.removeEventListener?.('change', onChange);
  }, [query]);
  return matches;
}
