/**
 * SVG board (spec §14, HANDOFF §6.3). Pure view: everything it draws comes from
 * `GameState`; geometry comes from the engine's `board/geometry` helpers so the
 * picture matches the graph the validator uses. Interaction is delegated
 * through `onNodeClick` / `onShipClick`; `highlights` marks the nodes the
 * current interaction may target (legal move ends, buildable sites, jump
 * targets) and, when a path is known, the preview drawn on hover.
 *
 * Face-down sectors (explorer / wild space): the board is drawn through
 * `redactBoard`, so an undiscovered slot shows as a neutral tile with a "?"
 * and none of its interior nodes, planets or docks — whether the state came
 * redacted from the server or is the hot-seat authority. The engine keeps
 * ships out of those interiors, so highlights match.
 */

import {
  hexCenter,
  hexCorners,
  redactBoard,
  vertexPosition,
  type GameState,
  type NodeId,
  type Planet,
  type PlayerId,
  type Sector,
  type Ship,
  type ShipId,
} from '@starfarers/shared';
import { useEffect, useMemo, useState } from 'react';
import { CIV_COLOR, CIV_LABEL, PLAYER_COLOR, RESOURCE_COLOR, dicePips, playerColor } from '../ui/format.js';
import { NO_MOTION, useFlips, useShipSlide, type BoardMotion, type Point } from './motion.js';
import { onActivateKey } from '../ui/keyboard.js';
import { COARSE_QUERY, useMediaQuery } from '../ui/media.js';
import { MAX_ZOOM, ZOOM_STEP, useBoardView } from './view.js';
import { DOCK_R, LABEL_FONT, outpostLayout } from './outpostLayout.js';

export const SCALE = 58;
/** Pointer radius of a highlighted node: just under half the edge length (33) so neighbours never overlap. */
const HIT_R = 16;
const PAD = 26;

export interface BoardProps {
  state: GameState;
  viewer: PlayerId | null;
  /** Node → path (nodes after the ship's node) for a move, or `null` when the node is just selectable. */
  highlights: ReadonlyMap<NodeId, NodeId[] | null>;
  selectedShip: ShipId | null;
  onNodeClick(nodeId: NodeId): void;
  onShipClick(shipId: ShipId): void;
  /** Latest live action to animate (motion.ts); absent = no animations. */
  motion?: BoardMotion | undefined;
  /** The viewer's ships may be selected right now: they join the tab order (HANDOFF §8.4). */
  shipsSelectable?: boolean | undefined;
  /** Touch: the node picked by a first tap, waiting for the confirm tap (HANDOFF §8.9a). Shows its path. */
  armedNode?: NodeId | null | undefined;
}

function nodeLabel(node: { id: NodeId; siteType?: string | undefined }, ship: Ship | undefined): string {
  const kind = node.siteType === 'colonySite' ? 'colony site' : node.siteType === 'dockingPoint' ? 'docking point' : 'intersection';
  return `${kind} ${node.id}${ship ? `, ${ship.kind} ship ${ship.id}` : ''}`;
}

function px(p: { x: number; y: number }): { x: number; y: number } {
  return { x: p.x * SCALE + PAD, y: p.y * SCALE + PAD };
}

function hexPoints(hex: readonly [number, number]): string {
  return hexCorners(hex)
    .map((id) => px(vertexPosition(id)))
    .map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`)
    .join(' ');
}

function PlanetHex({ planet, flip }: { planet: Planet; flip: boolean }) {
  const c = px(hexCenter(planet.hex));
  const disc = planet.disc;
  const token = planet.token;
  const r = SCALE * 0.27;
  let discNode = null;
  if (token) {
    const pirate = token.kind === 'pirateBase';
    discNode = (
      <g data-testid={`token-${planet.id}`} className={flip ? 'flip' : undefined}>
        <circle cx={c.x} cy={c.y} r={r} fill={pirate ? '#1b1b1b' : '#bfe3f2'} stroke={pirate ? '#ff5e5e' : '#2b7a99'} strokeWidth={2.5} />
        <text x={c.x} y={c.y + 5} textAnchor="middle" fontSize={14} fontWeight={700} fill={pirate ? '#ff5e5e' : '#114'}>
          {pirate ? 'P' : 'I'}
          {token.value}
        </text>
      </g>
    );
  } else if (disc && disc.faceUp) {
    const nums = disc.numbers;
    const best = Math.max(...nums.map(dicePips));
    const size = nums.length > 1 ? 11 : 9 + best * 1.7;
    const hot = best >= 5;
    discNode = (
      <g data-testid={`disc-${planet.id}`} className={flip ? 'flip' : undefined}>
        <circle cx={c.x} cy={c.y} r={r} fill="#f7f1dc" stroke="#4a4030" strokeWidth={1.5} />
        <text x={c.x} y={c.y + size * 0.36} textAnchor="middle" fontSize={size} fontWeight={700} fill={hot ? '#b3261e' : '#222'}>
          {disc.label}
        </text>
      </g>
    );
  } else if (disc) {
    discNode = (
      <circle data-testid={`disc-${planet.id}`} cx={c.x} cy={c.y} r={r} fill="#3b4150" stroke="#9aa3b5" strokeWidth={1.5} strokeDasharray="4 3" />
    );
  }
  return (
    <g>
      <polygon points={hexPoints(planet.hex)} fill={RESOURCE_COLOR[planet.resource]} fillOpacity={0.55} stroke="#0d1017" strokeWidth={1.2} />
      {discNode}
    </g>
  );
}

function Outpost({ state, sector, flip }: { state: GameState; sector: Sector; flip: boolean }) {
  const civ = sector.civ;
  if (!civ) return null;
  const docks = sector.docks ?? [];
  const layout = outpostLayout(sector, px);
  return (
    <g data-testid={`outpost-${sector.id}`} className={flip ? 'flip' : undefined}>
      {sector.lobes.map((hex) => (
        <polygon key={hex.join(',')} points={hexPoints(hex)} fill={CIV_COLOR[civ]} fillOpacity={0.45} stroke="#0d1017" strokeWidth={1.2} />
      ))}
      <text data-testid={`civ-label-${sector.id}`} x={layout.label.x} y={layout.label.y} textAnchor="middle" fontSize={LABEL_FONT} fill="#e8ecf4" fontWeight={600}>
        {CIV_LABEL[civ]}
      </text>
      {docks.map((owner, i) => {
        const at = layout.docks[i] ?? { x: 0, y: 0 };
        return (
          <circle
            key={i}
            data-testid={`dock-${sector.id}-${i}`}
            cx={at.x}
            cy={at.y}
            r={DOCK_R}
            fill={owner ? playerColor(state, owner) : '#1b2030'}
            stroke="#d8dde8"
            strokeWidth={1.2}
          />
        );
      })}
    </g>
  );
}

function EmptySector({ sector, flip }: { sector: Sector; flip: boolean }) {
  return (
    <g data-testid={`empty-${sector.id}`} className={flip ? 'flip' : undefined}>
      {sector.lobes.map((hex) => (
        <polygon key={hex.join(',')} points={hexPoints(hex)} fill="#141a26" stroke="#0d1017" strokeWidth={1.2} />
      ))}
    </g>
  );
}

function HiddenSector({ sector }: { sector: Sector }) {
  const centre = px(vertexPosition(sector.centreVertex));
  return (
    <g data-testid={`hidden-${sector.id}`}>
      {sector.lobes.map((hex) => (
        <polygon key={hex.join(',')} points={hexPoints(hex)} fill="#1c2233" stroke="#3a4360" strokeWidth={1.6} strokeDasharray="5 3" />
      ))}
      <circle cx={centre.x} cy={centre.y} r={SCALE * 0.3} fill="#232b3f" stroke="#4a5578" strokeWidth={1.5} />
      <text x={centre.x} y={centre.y + 7} textAnchor="middle" fontSize={20} fontWeight={700} fill="#8d97ab">
        ?
      </text>
    </g>
  );
}

function ShipGlyph({
  ship,
  state,
  selected,
  motion,
  posOf,
  focusable,
  onClick,
}: {
  ship: Ship;
  state: GameState;
  selected: boolean;
  motion: BoardMotion;
  posOf(id: NodeId): Point;
  focusable: boolean;
  onClick(): void;
}) {
  const p = px(state.board.nodes[ship.nodeId]?.pos ?? { x: 0, y: 0 });
  const slide = useShipSlide(ship.id, ship.nodeId, motion, posOf);
  const fill = playerColor(state, ship.owner);
  const stroke = selected ? '#ffffff' : '#0d1017';
  const shape =
    ship.kind === 'colony' ? (
      <polygon points={`${p.x},${p.y - 11} ${p.x + 9},${p.y + 8} ${p.x - 9},${p.y + 8}`} fill={fill} stroke={stroke} strokeWidth={selected ? 3 : 1.5} />
    ) : (
      <rect x={p.x - 10} y={p.y - 7} width={20} height={14} rx={4} fill={fill} stroke={stroke} strokeWidth={selected ? 3 : 1.5} />
    );
  return (
    <g
      data-testid={`ship-${ship.id}`}
      data-selected={selected ? 'true' : undefined}
      data-node={ship.nodeId}
      data-moving={slide ? 'true' : undefined}
      className="ship"
      tabIndex={focusable ? 0 : undefined}
      role={focusable ? 'button' : undefined}
      aria-label={focusable ? `${selected ? 'Deselect' : 'Select'} ${ship.kind} ship ${ship.id}` : undefined}
      aria-pressed={focusable ? selected : undefined}
      onKeyDown={focusable ? onActivateKey(onClick) : undefined}
      onClick={(e) => {
        e.stopPropagation();
        onClick();
      }}
    >
      <g className="ship-motion" style={slide}>
        {focusable && <circle className="focus-ring" cx={p.x} cy={p.y} r={15} fill="none" />}
        {shape}
        {ship.mustFoundOrLeave && (
          <text x={p.x + 10} y={p.y - 8} fontSize={12} fontWeight={700} fill="#ffd166">
            !
          </text>
        )}
      </g>
    </g>
  );
}

export function Board({ state, viewer, highlights, selectedShip, onNodeClick, onShipClick, motion = NO_MOTION, shipsSelectable = false, armedNode = null }: BoardProps) {
  const [hover, setHover] = useState<NodeId | null>(null);
  const board = useMemo(() => redactBoard(state.board), [state.board]);
  const flips = useFlips(board, motion);
  const posOf = (id: NodeId): Point => px(board.nodes[id]?.pos ?? { x: 0, y: 0 });

  const viewBox = useMemo(() => {
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const node of Object.values(board.nodes)) {
      const p = px(node.pos);
      minX = Math.min(minX, p.x);
      minY = Math.min(minY, p.y);
      maxX = Math.max(maxX, p.x);
      maxY = Math.max(maxY, p.y);
    }
    for (const sector of Object.values(board.sectors)) {
      for (const hex of sector.lobes) {
        for (const id of hexCorners(hex)) {
          const p = px(vertexPosition(id));
          minX = Math.min(minX, p.x);
          minY = Math.min(minY, p.y);
          maxX = Math.max(maxX, p.x);
          maxY = Math.max(maxY, p.y);
        }
      }
    }
    return `${minX - PAD} ${minY - PAD} ${maxX - minX + 2 * PAD} ${maxY - minY + 2 * PAD}`;
  }, [board.nodes, board.sectors]);

  const shipsByNode = useMemo(() => {
    const m = new Map<NodeId, Ship>();
    for (const ship of Object.values(board.ships)) m.set(ship.nodeId, ship);
    return m;
  }, [board.ships]);

  const view = useBoardView(viewBox);
  const coarse = useMediaQuery(COARSE_QUERY);
  // Touch: when targets light up, zoom to them so each is a finger-sized target (HANDOFF §8.9a).
  const highlightKey = [...highlights.keys()].sort().join(' ');
  const { focus } = view;
  useEffect(() => {
    if (!coarse || highlightKey === '') return;
    const ids = highlightKey.split(' ');
    const shipNode = selectedShip ? board.ships[selectedShip]?.nodeId : undefined;
    if (shipNode) ids.push(shipNode);
    const pts = ids.map((id) => px(board.nodes[id]?.pos ?? { x: 0, y: 0 }));
    const xs = pts.map((p) => p.x);
    const ys = pts.map((p) => p.y);
    const x = Math.min(...xs);
    const y = Math.min(...ys);
    focus({ x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y });
    // Keyed on the target set only: a new state with the same targets keeps the player's pan and zoom.
  }, [coarse, highlightKey, focus]);

  const sectors = Object.values(board.sectors);
  const selected = selectedShip ? board.ships[selectedShip] : undefined;
  const previewNode = armedNode ?? hover;
  const previewPath = previewNode && selected ? highlights.get(previewNode) : undefined;
  const previewPoints =
    previewPath && selected
      ? [selected.nodeId, ...previewPath]
          .map((id) => px(board.nodes[id]?.pos ?? { x: 0, y: 0 }))
          .map((p) => `${p.x},${p.y}`)
          .join(' ')
      : null;

  return (
    <div className="board-wrap">
    <svg className="board" viewBox={view.viewBox} role="group" aria-label="Game board" data-testid="board" ref={view.svgRef} {...view.handlers}>
      <g className="sectors">
        {sectors.map((sector) => {
          if (sector.kind === 'hidden') return <HiddenSector key={sector.id} sector={sector} />;
          const flip = flips.sectors.has(sector.id);
          if (sector.kind === 'outpost') return <Outpost key={sector.id} state={state} sector={sector} flip={flip} />;
          if (sector.kind === 'empty') return <EmptySector key={sector.id} sector={sector} flip={flip} />;
          return (
            <g key={sector.id} data-testid={`sector-${sector.id}`} className={flip ? 'flip' : undefined}>
              {sector.planetIds.map((pid) => {
                const planet = board.planets[pid];
                return planet ? <PlanetHex key={pid} planet={planet} flip={flips.discs.has(pid)} /> : null;
              })}
            </g>
          );
        })}
      </g>
      <g className="edges" stroke="#5b6478" strokeOpacity={0.35} strokeWidth={1}>
        {board.edges.map(([a, b]) => {
          const pa = px(board.nodes[a]?.pos ?? { x: 0, y: 0 });
          const pb = px(board.nodes[b]?.pos ?? { x: 0, y: 0 });
          return <line key={`${a}-${b}`} x1={pa.x} y1={pa.y} x2={pb.x} y2={pb.y} />;
        })}
      </g>
      {previewPoints && <polyline className="path-preview" points={previewPoints} fill="none" stroke="#ffd166" strokeWidth={3} strokeDasharray="6 4" />}
      <g className="nodes">
        {Object.values(board.nodes).map((node) => {
          const p = px(node.pos);
          const hl = highlights.has(node.id);
          const isSite = node.siteType === 'colonySite';
          const isDock = node.siteType === 'dockingPoint';
          const r = isSite || isDock ? 6 : 4;
          return (
            <g
              key={node.id}
              data-testid={`node-${node.id}`}
              data-highlight={hl ? 'true' : undefined}
              className={hl ? (node.id === armedNode ? 'node highlight armed' : 'node highlight') : 'node'}
              tabIndex={hl ? 0 : undefined}
              role={hl ? 'button' : undefined}
              aria-label={hl ? nodeLabel(node, shipsByNode.get(node.id)) : undefined}
              onKeyDown={hl ? onActivateKey(() => onNodeClick(node.id)) : undefined}
              onFocus={hl ? () => setHover(node.id) : undefined}
              onBlur={hl ? () => setHover((h) => (h === node.id ? null : h)) : undefined}
              onClick={() => onNodeClick(node.id)}
              onMouseEnter={() => setHover(node.id)}
              onMouseLeave={() => setHover((h) => (h === node.id ? null : h))}
            >
              {/* Invisible hit area: the halo alone is ~13 px wide when the board is scaled down. */}
              {hl && <circle cx={p.x} cy={p.y} r={HIT_R} className="hit" fill="transparent" />}
              {hl && <circle cx={p.x} cy={p.y} r={12} className="halo" fill="#ffd166" fillOpacity={0.25} stroke="#ffd166" strokeWidth={2} />}
              <circle cx={p.x} cy={p.y} r={r} fill={isDock ? '#f6c667' : isSite ? '#cfe3ff' : '#8d97ab'} stroke="#0d1017" strokeWidth={1} />
            </g>
          );
        })}
      </g>
      <g className="settlements">
        {Object.values(board.settlements).map((s) => {
          const p = px(board.nodes[s.nodeId]?.pos ?? { x: 0, y: 0 });
          const fill = PLAYER_COLOR[s.color];
          const blocker = s.owner === null;
          if (s.kind === 'spaceport') {
            return (
              <g key={s.nodeId} data-testid={`settlement-${s.nodeId}`} data-kind="spaceport" onClick={() => onNodeClick(s.nodeId)}>
                <rect x={p.x - 11} y={p.y - 11} width={22} height={22} rx={3} fill={fill} stroke="#0d1017" strokeWidth={1.5} strokeDasharray={blocker ? '3 2' : undefined} />
                <circle cx={p.x} cy={p.y} r={4.5} fill="#0d1017" />
              </g>
            );
          }
          return (
            <rect
              key={s.nodeId}
              data-testid={`settlement-${s.nodeId}`}
              data-kind="colony"
              x={p.x - 7}
              y={p.y - 7}
              width={14}
              height={14}
              fill={fill}
              stroke="#0d1017"
              strokeWidth={1.5}
              strokeDasharray={blocker ? '3 2' : undefined}
              onClick={() => onNodeClick(s.nodeId)}
            />
          );
        })}
      </g>
      <g className="ships">
        {[...shipsByNode.values()].map((ship) => (
          <ShipGlyph
            key={ship.id}
            ship={ship}
            state={state}
            selected={ship.id === selectedShip}
            motion={motion}
            posOf={posOf}
            focusable={shipsSelectable && ship.owner === viewer}
            onClick={() => {
              // Clicking a highlighted node that happens to hold a ship is a move/pick target.
              if (highlights.has(ship.nodeId)) onNodeClick(ship.nodeId);
              else if (ship.owner === viewer) onShipClick(ship.id);
              else onNodeClick(ship.nodeId);
            }}
          />
        ))}
      </g>
    </svg>
      {/* Touch-screen alternatives to pinch and drag; hidden on laptops by styles.css. */}
      <div className="board-zoom" role="group" aria-label="Board zoom">
        <button type="button" aria-label="Zoom in" data-testid="zoom-in" onClick={() => view.zoomBy(ZOOM_STEP)} disabled={view.zoom >= MAX_ZOOM - 0.01}>
          +
        </button>
        <button type="button" aria-label="Zoom out" data-testid="zoom-out" onClick={() => view.zoomBy(1 / ZOOM_STEP)} disabled={view.zoom <= 1.01}>
          −
        </button>
        <button type="button" aria-label="Show the whole board" data-testid="zoom-fit" onClick={view.fit} disabled={view.zoom <= 1.01}>
          Fit
        </button>
      </div>
    </div>
  );
}
