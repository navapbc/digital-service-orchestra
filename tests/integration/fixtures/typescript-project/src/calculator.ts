/**
 * Calculator module — target for add-parameter integration tests.
 */

export function add(x: number, y: number): number {
  return x + y;
}

export function subtract(x: number, y: number): number {
  return x - y;
}

export function multiply(x: number, y: number): number {
  return x * y;
}

export function divide(x: number, y: number): number {
  if (y === 0) return 0;
  return x / y;
}

export function power(base: number, exponent: number): number {
  return Math.pow(base, exponent);
}
