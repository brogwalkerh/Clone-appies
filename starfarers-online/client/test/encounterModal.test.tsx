import { ENCOUNTER_CARDS, type EncounterPickKind, type EncounterPickRequest, type GameState } from '@starfarers/shared';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { EncounterModal } from '../src/panels/EncounterModal.js';
import { gameStore } from '../src/store/gameStore.js';
import { game, setup } from './fixtures.js';

function withAwaiting(kind: EncounterPickKind, extra: Partial<EncounterPickRequest> = {}): GameState {
  const s = game();
  s.phase = 'flight.encounter';
  s.turn.encounter = {
    cardId: 1,
    stage: 'resolving',
    revealed: ['A ship hails you.', 'You offer 2 cards.'],
    queue: [],
    awaiting: { kind, playerId: s.activePlayer, effect: { type: 'gainResource', resource: 'any', count: 1 }, ...extra },
  };
  return s;
}

function mount(state: GameState, viewer = state.activePlayer) {
  gameStore.getState().loadGame(setup(), state);
  return render(<EncounterModal state={state} viewer={viewer} />);
}

describe('EncounterModal', () => {
  it('reveals the text boxes in order', () => {
    mount(withAwaiting('resources', { count: 1 }));
    const boxes = screen.getAllByTestId('encounter-box').map((b) => b.textContent);
    expect(boxes).toEqual(['A ship hails you.', 'You offer 2 cards.']);
    expect(screen.getByText(/Encounter #1: Hungry traders/)).toBeInTheDocument();
  });

  const singleChoice: [EncounterPickKind, string[]][] = [
    ['upgradeKind', ['booster', 'cannon']],
    ['removeUpgrade', ['booster']],
    ['immobilizeShip', ['ship:red:1']],
    ['spaceJump', ['ship:red:1']],
  ];
  for (const [kind, options] of singleChoice) {
    it(`renders one button per option for ${kind}`, () => {
      mount(withAwaiting(kind, { options }));
      expect(screen.getByTestId(`pick-${kind}`)).toBeInTheDocument();
      for (const o of options) expect(screen.getByTestId(`pick-option-${o}`)).toBeInTheDocument();
      if (kind === 'spaceJump') expect(screen.getByTestId('pick-decline')).toBeInTheDocument();
    });
  }

  for (const kind of ['resources', 'payResources', 'giveOne'] as const) {
    it(`renders a card picker bounded by count for ${kind}`, async () => {
      const s = withAwaiting(kind, { count: 2 });
      // Give the picking player enough cards for the hand-bounded kinds.
      const me = s.players.find((p) => p.id === s.activePlayer)!;
      me.hand = ['ore', 'ore', 'fuel'];
      mount(s);
      expect(screen.getByTestId(`pick-${kind}`)).toBeInTheDocument();
      const confirm = screen.getByTestId('pick-confirm');
      expect(confirm).toBeDisabled();
      await userEvent.click(screen.getAllByLabelText('more ore')[0]!);
      await userEvent.click(screen.getAllByLabelText('more ore')[0]!);
      expect(screen.getByTestId('pick-ore').textContent).toBe('2');
      expect(confirm).toBeEnabled();
      // A third card is refused by the picker (count bound).
      expect(screen.getAllByLabelText('more fuel')[0]).toBeDisabled();
    });
  }

  it('tells a non-picking viewer who it waits for', () => {
    const s = withAwaiting('giveOne', { playerId: 'p2', count: 1 });
    mount(s, 'p1');
    expect(screen.getByText(/Waiting for Bob/)).toBeInTheDocument();
    expect(screen.queryByTestId('pick-confirm')).not.toBeInTheDocument();
  });

  it('shows the offer picker for offer cards and yes/no for yes/no cards', () => {
    const offerCard = ENCOUNTER_CARDS.find((c) => c.choice === 'offer0to3')!;
    const yesnoCard = ENCOUNTER_CARDS.find((c) => c.choice === 'yesno')!;
    const s = game();
    s.phase = 'flight.encounter';
    s.turn.encounter = { cardId: offerCard.id, stage: 'choice', revealed: [offerCard.prompt], queue: [] };
    const { unmount } = mount(s);
    expect(screen.getByTestId('choice-offer')).toBeInTheDocument();
    unmount();
    s.turn.encounter = { cardId: yesnoCard.id, stage: 'choice', revealed: [yesnoCard.prompt], queue: [] };
    mount(s);
    expect(screen.getByTestId('choice-yesno')).toBeInTheDocument();
  });

  it('after an offer-then-yes/no card took the offer, only yes/no remains', () => {
    const card = ENCOUNTER_CARDS.find((c) => c.choice === 'offerThenYesno')!;
    const s = game();
    s.phase = 'flight.encounter';
    s.turn.encounter = { cardId: card.id, stage: 'choice', offerPaid: ['ore'], revealed: [card.prompt], queue: [] };
    mount(s);
    expect(screen.queryByTestId('choice-offer')).not.toBeInTheDocument();
    expect(screen.getByTestId('choice-yesno')).toBeInTheDocument();
  });

  it('stays visible with a Continue button once the card is done, and dismisses', async () => {
    const s = game();
    s.phase = 'flight.move';
    s.turn.encounter = { cardId: 1, stage: 'done', revealed: ['done text'], queue: [] };
    mount(s);
    expect(screen.getByText('done text')).toBeInTheDocument();
    await userEvent.click(screen.getByTestId('encounter-continue'));
    expect(screen.queryByTestId('encounter-modal')).not.toBeInTheDocument();
  });
});
