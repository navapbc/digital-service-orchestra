/**
 * Parser module — has unsorted imports for normalize-imports tests.
 */
import { formatNumber } from './utils';
import { flatten } from './utils';
import { formatSum } from './formatter';
import { add } from './calculator';

export function parseInt(value: unknown): number | null {
  const n = Number(value);
  if (!Number.isInteger(n)) return null;
  return n;
}

export function parseFloat(value: unknown): number | null {
  const n = Number(value);
  if (isNaN(n)) return null;
  return n;
}

export function parseList(value: string, separator: string = ','): string[] {
  if (!value) return [];
  return value.split(separator).map((v) => v.trim()).filter((v) => v.length > 0);
}

export function parseNumberList(value: string): number[] {
  const tokens = parseList(value);
  return tokens.map((t) => Number(t)).filter((n) => !isNaN(n));
}
