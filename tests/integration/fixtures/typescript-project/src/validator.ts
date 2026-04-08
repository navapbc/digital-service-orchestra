/**
 * Validator module — calls calculator and exports validation functions.
 */
import { add, subtract, divide } from './calculator';
import { clamp, safeDivide } from './utils';

export function isPositive(value: number): boolean {
  return value > 0;
}

export function isInRange(value: number, low: number, high: number): boolean {
  return clamp(value, low, high) === value;
}

export function validateRatio(
  numerator: number,
  denominator: number,
  minRatio: number = 0.0,
  maxRatio: number = 1.0,
): boolean {
  const ratio = safeDivide(numerator, denominator);
  return ratio >= minRatio && ratio <= maxRatio;
}

export function validateSum(x: number, y: number, expected: number): boolean {
  const result = add(x, y);
  return Math.abs(result - expected) < 1e-9;
}

export function validateDifference(x: number, y: number, expected: number): boolean {
  const result = subtract(x, y);
  return Math.abs(result - expected) < 1e-9;
}
