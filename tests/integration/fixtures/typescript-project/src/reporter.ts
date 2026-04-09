/**
 * Reporter module — calls calculator, formatter, and validator.
 */
import { add, multiply, power } from './calculator';
import { formatSum, formatProduct, formatTable } from './formatter';
import { isPositive, validateRatio } from './validator';

export function reportSum(x: number, y: number): string {
  const result = add(x, y);
  const label = isPositive(result) ? 'positive' : 'non-positive';
  return `sum(${x}, ${y}) = ${formatSum(x, y)} [${label}]`;
}

export function reportProduct(x: number, y: number): string {
  const result = multiply(x, y);
  const label = isPositive(result) ? 'positive' : 'non-positive';
  return `product(${x}, ${y}) = ${formatProduct(x, y)} [${label}]`;
}

export function reportTable(pairs: [number, number][]): string {
  return 'Sums:\n' + formatTable(pairs);
}

export function reportPowerSeries(base: number, maxExp: number): number[] {
  return Array.from({ length: maxExp + 1 }, (_, n) => power(base, n));
}
