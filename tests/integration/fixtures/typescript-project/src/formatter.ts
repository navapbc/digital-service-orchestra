/**
 * Formatting module — calls calculator functions.
 * Has intentionally unsorted imports for normalize-imports tests.
 */
import { formatNumber } from './utils';
import { multiply, divide } from './calculator';
import { add } from './calculator';

export function formatSum(x: number, y: number): string {
  const result = add(x, y);
  return formatNumber(result);
}

export function formatProduct(x: number, y: number): string {
  const result = multiply(x, y);
  return formatNumber(result);
}

export function formatRatio(x: number, y: number): string {
  const result = divide(x, y);
  return formatNumber(result, 4);
}

export function formatTable(pairs: [number, number][]): string {
  return pairs.map(([x, y]) => `  ${x} + ${y} = ${formatSum(x, y)}`).join('\n');
}
