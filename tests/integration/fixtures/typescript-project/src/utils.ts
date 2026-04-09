/**
 * Utility functions for the TypeScript fixture project.
 */

export function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

export function safeDivide(numerator: number, denominator: number): number {
  if (denominator === 0) return 0;
  return numerator / denominator;
}

export function flatten<T>(nested: T[][]): T[] {
  return nested.reduce((acc: T[], arr: T[]) => acc.concat(arr), []);
}

export function formatNumber(value: number, decimals: number = 2): string {
  return value.toFixed(decimals);
}
