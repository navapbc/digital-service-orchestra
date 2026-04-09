/**
 * Minimal tests for calculator.ts — skip test runner requirement for integration tests.
 */
import { add, subtract, multiply, divide, power } from '../src/calculator';

describe('calculator', () => {
  test('add returns sum', () => {
    expect(add(2, 3)).toBe(5);
  });

  test('subtract returns difference', () => {
    expect(subtract(10, 4)).toBe(6);
  });

  test('multiply returns product', () => {
    expect(multiply(3, 7)).toBe(21);
  });

  test('divide returns quotient', () => {
    expect(divide(10, 2)).toBe(5);
  });

  test('divide by zero returns 0', () => {
    expect(divide(5, 0)).toBe(0);
  });

  test('power returns base raised to exponent', () => {
    expect(power(2, 8)).toBe(256);
  });
});
