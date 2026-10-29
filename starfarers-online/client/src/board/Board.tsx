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
import { useMemo, useState } from 'react';
import { CIV_LABEL, dicePips } from '../ui/format.js';
import { NO_MOTION, useFlips, useShipSlide, type BoardMotion, type Point } from './motion.js';
import { onActivateKey } from '../ui/keyboard.js';
import { DOCK_R, LABEL_FONT, outpostLayout } from './outpostLayout.js';
import { BoardDefs, INK, civFill, pieceFill, planetFill, tileFill } from './palette.js';

export const SCALE = 58;
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
}

function nodeLabel(node: { id: NodeId; siteType?: string | undefined }, ship: Ship | undefined): string {
  const kind = node.siteType === 'colonySite' ? 'colony site' : node.siteType === 'dockingPoint' ? 'docking point' : 'intersection';
  return `${kind} ${node.id}${ship ? `, ${ship.kind} ship ${ship.id}` : ''}`;
}

function px(p: { x: number; y: number }): { x: number; y: number } {
  return { x: p.x * SCALE + PAD, y: p.y * SCALE + PAD };
}

/** The hex outline, shrunk toward its centre by `inset` (0 = the tile edge). */
function hexPoints(hex: readonly [number, number], inset = 0): string {
  const c = px(hexCenter(hex));
  return hexCorners(hex)
    .map((id) => px(vertexPosition(id)))
    .map((p) => ({ x: p.x + (c.x - p.x) * inset, y: p.y + (c.y - p.y) * inset }))
    .map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`)
    .join(' ');
}

/** A player's piece gradient (grey for an unknown owner). */
function ownerFill(state: GameState, id: PlayerId): string {
  const p = state.players.find((x) => x.id === id);
  return p ? pieceFill(p.color) : '#777';
}

/** A printed card tile: fill, dark cut edge, and a light bevel just inside it. */
function Tile({ hex, fill }: { hex: readonly [number, number]; fill: string }) {
  return (
    <>
      <polygon points={hexPoints(hex)} fill={fill} stroke={INK.line} strokeWidth={2.2} strokeLinejoin="round" />
      <polygon points={hexPoints(hex, 0.07)} fill="none" stroke="#ffffff" strokeOpacity={0.16} strokeWidth={1.2} strokeLinejoin="round" />
    </>
  );
}

/** Pieces are drawn at their node's coordinates and enlarged about it, so the geometry stays at the node. */
const PIECE_SCALE = 1.3;
const enlarge = (p: { x: number; y: number }) => `translate(${p.x} ${p.y}) scale(${PIECE_SCALE}) translate(${-p.x} ${-p.y})`;

/** Highlight stripe across the top of a piece so it reads as moulded plastic. */
function Gloss({ x, y, w }: { x: number; y: number; w: number }) {
  return <rect x={x - w / 2} y={y} width={w} height={2.2} rx={1.1} fill="#ffffff" fillOpacity={0.45} pointerEvents="none" />;
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
      <g data-testid={`token-${planet.id}`} className={flip ? 'flip token' : 'token'}>
        <circle cx={c.x} cy={c.y} r={r} fill={pirate ? '#1f1a1a' : '#d7eef7'} stroke={pirate ? '#ff5e5e' : '#2b7a99'} strokeWidth={2.5} />
        <circle cx={c.x} cy={c.y} r={r - 4} fill="none" stroke={pirate ? '#ff5e5e' : '#2b7a99'} strokeOpacity={0.4} strokeWidth={1} />
        <text x={c.x} y={c.y + 5} textAnchor="middle" className="token-num" fontSize={15} fill={pirate ? '#ff6b6b' : '#113'}>
          {pirate ? 'P' : 'I'}
          {token.value}
        </text>
      </g>
    );
  } else if (disc && disc.faceUp) {
    const nums = disc.numbers;
    const best = Math.max(...nums.map(dicePips));
    const size = nums.length > 1 ? 13 : 11 + best * 1.9;
    const hot = best >= 5;
    discNode = (
      <g data-testid={`disc-${planet.id}`} className={flip ? 'flip token' : 'token'}>
        <circle cx={c.x} cy={c.y} r={r} fill="url(#token-face)" stroke={INK.tokenRim} strokeWidth={1.5} />
        <circle cx={c.x} cy={c.y} r={r - 3.5} fill="none" stroke={INK.tokenRim} strokeOpacity={0.35} strokeWidth={0.8} />
        <text x={c.x} y={c.y + size * 0.35} textAnchor="middle" className="token-num" fontSize={size} fill={hot ? INK.tokenHot : INK.tokenInk}>
          {disc.label}
        </text>
      </g>
    );
  } else if (disc) {
    // Face-down: the printed back of the disc, a ring and a four-point star.
    const s = r * 0.5;
    discNode = (
      <g data-testid={`disc-${planet.id}`} className="token">
        <circle cx={c.x} cy={c.y} r={r} fill="url(#token-back)" stroke={INK.brass} strokeWidth={1.5} />
        <circle cx={c.x} cy={c.y} r={r - 4} fill="none" stroke={INK.brass} strokeOpacity={0.45} strokeWidth={0.8} />
        <path
          d={`M${c.x},${c.y - s} Q${c.x},${c.y} ${c.x + s},${c.y} Q${c.x},${c.y} ${c.x},${c.y + s} Q${c.x},${c.y} ${c.x - s},${c.y} Q${c.x},${c.y} ${c.x},${c.y - s}Z`}
          fill={INK.brass}
          fillOpacity={0.8}
        />
      </g>
    );
  }
  return (
    <g>
      <Tile hex={planet.hex} fill={tileFill(planet.resource)} />
      <circle cx={c.x} cy={c.y} r={SCALE * 0.42} fill={planetFill(planet.resource)} stroke={INK.line} strokeOpacity={0.6} strokeWidth={1} />
      {planet.resource === 'goods' && (
        <ellipse cx={c.x} cy={c.y} rx={SCALE * 0.52} ry={SCALE * 0.12} fill="none" stroke="#e8d7ff" strokeOpacity={0.55} strokeWidth={2} transform={`rotate(-18 ${c.x} ${c.y})`} />
      )}
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
        <Tile key={hex.join(',')} hex={hex} fill={civFill(civ)} />
      ))}
      <text data-testid={`civ-label-${sector.id}`} x={layout.label.x} y={layout.label.y} textAnchor="middle" fontSize={LABEL_FONT + 1} className="civ-label">
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
            fill={owner ? ownerFill(state, owner) : '#0c1226'}
            stroke={owner ? INK.line : INK.dock}
            strokeWidth={1.4}
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
        <Tile key={hex.join(',')} hex={hex} fill={INK.empty} />
      ))}
    </g>
  );
}

function HiddenSector({ sector }: { sector: Sector }) {
  const centre = px(vertexPosition(sector.centreVertex));
  return (
    <g data-testid={`hidden-${sector.id}`}>
      {sector.lobes.map((hex) => (
        <g key={hex.join(',')}>
          <Tile hex={hex} fill="url(#tile-back)" />
          <polygon points={hexPoints(hex, 0.22)} fill="none" stroke={INK.brass} strokeOpacity={0.35} strokeWidth={1} />
        </g>
      ))}
      <circle cx={centre.x} cy={centre.y} r={SCALE * 0.3} fill="url(#token-back)" stroke={INK.brass} strokeWidth={1.5} />
      <text x={centre.x} y={centre.y + 8} textAnchor="middle" className="token-num" fontSize={22} fill={INK.brass}>
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
  const fill = ownerFill(state, ship.owner);
  const stroke = selected ? INK.selected : INK.line;
  const width = selected ? 3 : 1.5;
  // Colony ship: an arrowhead hull with a notched tail; transport: a cargo hull with a hatch.
  // The first polygon / rect keeps the anchor the tests read (apex and right-hand foot / top-left corner).
  const shape =
    ship.kind === 'colony' ? (
      <>
        <polygon
          points={`${p.x},${p.y - 13} ${p.x + 10},${p.y + 8} ${p.x},${p.y + 4} ${p.x - 10},${p.y + 8}`}
          fill={fill}
          stroke={stroke}
          strokeWidth={width}
          strokeLinejoin="round"
        />
        <circle cx={p.x} cy={p.y - 2} r={2.2} fill={INK.line} fillOpacity={0.55} />
      </>
    ) : (
      <>
        <rect x={p.x - 10} y={p.y - 7} width={20} height={14} rx={4} fill={fill} stroke={stroke} strokeWidth={width} />
        <line x1={p.x - 4} y1={p.y - 4} x2={p.x - 4} y2={p.y + 4} stroke={INK.line} strokeOpacity={0.45} strokeWidth={1.2} />
        <line x1={p.x + 4} y1={p.y - 4} x2={p.x + 4} y2={p.y + 4} stroke={INK.line} strokeOpacity={0.45} strokeWidth={1.2} />
        <Gloss x={p.x} y={p.y - 5.5} w={14} />
      </>
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
        {focusable && <circle className="focus-ring" cx={p.x} cy={p.y} r={18} fill="none" />}
        <g transform={enlarge(p)}>{shape}</g>
        {ship.mustFoundOrLeave && (
          <text x={p.x + 10} y={p.y - 8} fontSize={13} className="token-num" fill={INK.highlight}>
            !
          </text>
        )}
      </g>
    </g>
  );
}

export function Board({ state, viewer, highlights, selectedShip, onNodeClick, onShipClick, motion = NO_MOTION, shipsSelectable = false }: BoardProps) {
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

  const sectors = Object.values(board.sectors);
  const selected = selectedShip ? board.ships[selectedShip] : undefined;
  const previewPath = hover && selected ? highlights.get(hover) : undefined;
  const previewPoints =
    previewPath && selected
      ? [selected.nodeId, ...previewPath]
          .map((id) => px(board.nodes[id]?.pos ?? { x: 0, y: 0 }))
          .map((p) => `${p.x},${p.y}`)
          .join(' ')
      : null;

  return (
    <svg className="board" viewBox={viewBox} role="group" aria-label="Game board" data-testid="board">
      <BoardDefs />
      <g className="sectors" filter="url(#lay)">
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
      <g className="edges" stroke={INK.lane} strokeOpacity={0.28} strokeWidth={1} strokeDasharray="2 3">
        {board.edges.map(([a, b]) => {
          const pa = px(board.nodes[a]?.pos ?? { x: 0, y: 0 });
          const pb = px(board.nodes[b]?.pos ?? { x: 0, y: 0 });
          return <line key={`${a}-${b}`} x1={pa.x} y1={pa.y} x2={pb.x} y2={pb.y} />;
        })}
      </g>
      {previewPoints && <polyline className="path-preview" points={previewPoints} fill="none" stroke={INK.highlight} strokeWidth={3} strokeDasharray="6 4" strokeLinecap="round" />}
      <g className="nodes">
        {Object.values(board.nodes).map((node) => {
          const p = px(node.pos);
          const hl = highlights.has(node.id);
          const isSite = node.siteType === 'colonySite';
          const isDock = node.siteType === 'dockingPoint';
          const r = isDock ? 5 : isSite ? 4.5 : 2.6;
          return (
            <g
              key={node.id}
              data-testid={`node-${node.id}`}
              data-highlight={hl ? 'true' : undefined}
              className={hl ? 'node highlight' : 'node'}
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
              <circle cx={p.x} cy={p.y} r={9} fill="transparent" />
              {hl && <circle cx={p.x} cy={p.y} r={12} className="halo" fill={INK.highlight} fillOpacity={0.25} stroke={INK.highlight} strokeWidth={2} />}
              {/* Printed studs: a ring for colony sites, a gold pip for docking points, a small dot elsewhere. The dot is the last circle. */}
              <circle
                cx={p.x}
                cy={p.y}
                r={r}
                fill={isDock ? INK.dock : isSite ? '#0c1430' : INK.stud}
                fillOpacity={isSite || isDock ? 1 : 0.7}
                stroke={isSite ? INK.site : INK.line}
                strokeWidth={isSite ? 1.6 : 1}
              />
            </g>
          );
        })}
      </g>
      <g className="settlements" filter="url(#stand)">
        {Object.values(board.settlements).map((s) => {
          const p = px(board.nodes[s.nodeId]?.pos ?? { x: 0, y: 0 });
          const fill = pieceFill(s.color);
          const blocker = s.owner === null;
          const dash = blocker ? '3 2' : undefined;
          if (s.kind === 'spaceport') {
            // Station: a hexagonal deck with a docking ring.
            const hexPts = [0, 1, 2, 3, 4, 5]
              .map((i) => {
                const a = (Math.PI / 3) * i + Math.PI / 6;
                return `${(p.x + 13 * Math.cos(a)).toFixed(1)},${(p.y + 13 * Math.sin(a)).toFixed(1)}`;
              })
              .join(' ');
            return (
              <g key={s.nodeId} data-testid={`settlement-${s.nodeId}`} data-kind="spaceport" transform={enlarge(p)} onClick={() => onNodeClick(s.nodeId)}>
                <polygon points={hexPts} fill={fill} stroke={INK.line} strokeWidth={1.6} strokeLinejoin="round" strokeDasharray={dash} />
                <circle cx={p.x} cy={p.y} r={6} fill="none" stroke={INK.line} strokeOpacity={0.6} strokeWidth={1.4} />
                <circle cx={p.x} cy={p.y} r={2.4} fill={INK.line} />
                <Gloss x={p.x} y={p.y - 10} w={10} />
              </g>
            );
          }
          // Colony: a domed habitat on a base plate.
          return (
            <g key={s.nodeId} data-testid={`settlement-${s.nodeId}`} data-kind="colony" transform={enlarge(p)} onClick={() => onNodeClick(s.nodeId)}>
              <path
                d={`M${p.x - 8},${p.y + 7} L${p.x - 8},${p.y + 1} A8,8 0 0 1 ${p.x + 8},${p.y + 1} L${p.x + 8},${p.y + 7} Z`}
                fill={fill}
                stroke={INK.line}
                strokeWidth={1.5}
                strokeLinejoin="round"
                strokeDasharray={dash}
              />
              <path d={`M${p.x - 4.5},${p.y - 3} A5,5 0 0 1 ${p.x + 1},${p.y - 5.5}`} fill="none" stroke="#ffffff" strokeOpacity={0.55} strokeWidth={1.6} strokeLinecap="round" />
            </g>
          );
        })}
      </g>
      <g className="ships" filter="url(#stand)">
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
  );
}
