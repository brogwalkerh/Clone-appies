import { RESOURCES, type Resource, type ResourceBag } from '@starfarers/shared';
import { RESOURCE_COLOR, RESOURCE_LABEL } from '../ui/format.js';

export interface BagPickerProps {
  value: ResourceBag;
  onChange(bag: ResourceBag): void;
  /** Upper bound per resource (e.g. the hand); omit for unbounded. */
  max?: Partial<Record<Resource, number>> | undefined;
  /** Total cards allowed; omit for unbounded. */
  maxTotal?: number | undefined;
  testId?: string | undefined;
}

/** +/- steppers per resource that build a `ResourceBag`. */
export function BagPicker({ value, onChange, max, maxTotal, testId }: BagPickerProps) {
  const total = RESOURCES.reduce((n, r) => n + (value[r] ?? 0), 0);
  return (
    <div className="bag-picker" data-testid={testId}>
      {RESOURCES.map((r) => {
        const n = value[r] ?? 0;
        const cap = max?.[r];
        const canAdd = (cap === undefined || n < cap) && (maxTotal === undefined || total < maxTotal);
        if (cap === 0 && max !== undefined) return null;
        return (
          <div key={r} className="bag-row" style={{ borderColor: RESOURCE_COLOR[r] }}>
            <span className="card-name">{RESOURCE_LABEL[r]}</span>
            <button type="button" aria-label={`fewer ${r}`} disabled={n === 0} onClick={() => onChange({ ...value, [r]: n - 1 })}>
              −
            </button>
            <span data-testid={testId ? `${testId}-${r}` : undefined}>{n}</span>
            <button type="button" aria-label={`more ${r}`} disabled={!canAdd} onClick={() => onChange({ ...value, [r]: n + 1 })}>
              +
            </button>
          </div>
        );
      })}
    </div>
  );
}

export function bagToList(bag: ResourceBag): Resource[] {
  const out: Resource[] = [];
  for (const r of RESOURCES) for (let i = 0; i < (bag[r] ?? 0); i++) out.push(r);
  return out;
}
