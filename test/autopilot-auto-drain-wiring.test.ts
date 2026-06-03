/**
 * #1685 GAP D — autopilot auto-drain wiring regression guards.
 *
 * The submission is inline in the autopilot tick body, so these are
 * source-shape assertions (the proven `autopilot-*-wiring.test.ts` pattern).
 * The load-bearing one is CODEX #2: the idempotency key MUST carry a time slot,
 * else queue.add returns the first completed job forever and the source never
 * drains again.
 */
import { describe, test, expect } from 'bun:test';
import { readFileSync } from 'fs';
import { join } from 'path';

const SRC = readFileSync(join(import.meta.dir, '../src/commands/autopilot.ts'), 'utf8');

describe('autopilot auto-drain wiring', () => {
  test('CODEX #2: idempotency key includes a UTC-day time slot (not static)', () => {
    expect(SRC).toContain('autopilot-extract-atoms-drain:${src.id}:${utcDay}');
    // A static key would be the regression — guard against the bare form.
    expect(SRC).not.toContain('`autopilot-extract-atoms-drain:${src.id}`');
  });

  test('CODEX #1: submits with allowProtectedSubmit', () => {
    expect(SRC).toMatch(/extract-atoms-drain[\s\S]{0,800}allowProtectedSubmit: true/);
  });

  test('CODEX #3: enumerates sources and counts backlog per source', () => {
    expect(SRC).toContain('loadAllSources(engine)');
    expect(SRC).toContain('countExtractAtomsBacklog(engine, src.id)');
  });

  test('gates on pack NOT declaring extract_atoms (the silent-backlog condition)', () => {
    expect(SRC).toContain("packDeclaresPhase(engine, 'extract_atoms')");
  });

  test('gates on the enabled flag and a daily spend cap (DECISION 3C)', () => {
    expect(SRC).toContain('autopilot.auto_drain.enabled');
    expect(SRC).toContain('autopilot.auto_drain.max_usd_per_day');
    expect(SRC).toContain('maxJobsToday');
  });

  test('is Postgres-gated (PGLite has no worker surface)', () => {
    expect(SRC).toMatch(/engine\.kind === 'postgres'[\s\S]{0,400}auto_drain/);
  });
});
