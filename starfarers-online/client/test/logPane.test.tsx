/**
 * The log keeps its newest entry in view by scrolling its own list. It must
 * not use `scrollIntoView`, which also scrolls every scrollable ancestor: in
 * the game screen that dragged the side column down and cut off the hand.
 */

import { render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { LogPane } from '../src/panels/LogPane.js';
import { StoreContext, createGameStore } from '../src/store/gameStore.js';
import { game, setup } from './fixtures.js';

const proto = HTMLElement.prototype;

afterEach(() => {
  // Both were defined on HTMLElement.prototype by the test; the originals live further up the chain.
  Reflect.deleteProperty(proto, 'scrollHeight');
  Reflect.deleteProperty(proto, 'scrollIntoView');
});

describe('log auto-scroll', () => {
  it('scrolls the list to its end on mount and on each new entry, without scrollIntoView', () => {
    // jsdom has no layout: give every element a content height that grows with its children.
    Object.defineProperty(proto, 'scrollHeight', { configurable: true, get(this: HTMLElement) { return this.childElementCount * 20; } });
    const scrollIntoView = vi.fn();
    Object.defineProperty(proto, 'scrollIntoView', { configurable: true, value: scrollIntoView });

    const store = createGameStore();
    store.getState().loadGame(setup(), game());
    const pane = (state = store.getState().game!) => (
      <StoreContext.Provider value={store}>
        <LogPane state={state} />
      </StoreContext.Provider>
    );
    const { rerender } = render(pane());
    const list = screen.getByTestId('log-list');
    const before = store.getState().game!.log.length;
    expect(list.scrollTop).toBe(before * 20);

    const s = store.getState().game!;
    expect(store.getState().dispatch({ type: 'rollDice', playerId: s.activePlayer })).toBe(true);
    const after = store.getState().game!.log.length;
    expect(after).toBeGreaterThan(before);
    rerender(pane());
    expect(list.scrollTop).toBe(after * 20);
    expect(scrollIntoView).not.toHaveBeenCalled();
  });
});
