/**
 * Processor module — calls from multiple modules.
 */
import { flatten, safeDivide, formatNumber } from './utils';
import { reportSum, reportTable, reportPowerSeries } from './reporter';

export function processBatch(pairs: [number, number][]): string[] {
  return pairs.map(([x, y]) => reportSum(x, y));
}

export function processTable(pairs: [number, number][]): string {
  return reportTable(pairs);
}

export function processAverages(values: number[]): number {
  const total = values.reduce((a, b) => a + b, 0);
  return safeDivide(total, values.length);
}

export function processPowerSeries(base: number, maxExp: number): string[] {
  const series = reportPowerSeries(base, maxExp);
  return series.map((v) => formatNumber(v));
}

export function processFlattenAndSum(nested: number[][]): number {
  const flat = flatten(nested);
  return flat.reduce((a, b) => a + b, 0);
}
