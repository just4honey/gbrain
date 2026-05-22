/**
 * v0.38.2.0 — partial-scan state tests for scanBrainSources.
 *
 * Codex outside-voice C1 caught that AbortSignal.timeout cannot interrupt
 * the sync walker (event loop blocked by readdirSync / readFileSync). The
 * load-bearing interruption mechanism is `deadline?: number` checked
 * inside scanOneSource's visit closure before parsing each file.
 *
 * These tests use `deadline: Date.now() - 1` (already-expired) to force
 * partial state deterministically — NOT AbortSignal, which doesn't fire
 * in the sync loop and would make this test flake or never trigger.
 *
 * They also cover codex C2 (`ok` after abort must be false even on clean
 * prefix), C4 (`files_scanned` numerator surfaced), and the
 * `aborted_at_source` field that lets doctor name the partial source.
 */
import { describe, expect, test, beforeAll, afterAll, beforeEach } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { scanBrainSources } from '../src/core/brain-writer.ts';
import { PGLiteEngine } from '../src/core/pglite-engine.ts';
import { resetPgliteState } from './helpers/reset-pglite.ts';

let engine: PGLiteEngine;
let sourceA: string;
let sourceB: string;
let sourceC: string;

beforeAll(async () => {
  engine = new PGLiteEngine();
  await engine.connect({});
  await engine.initSchema();

  // Three source dirs, each with a few markdown files.
  sourceA = mkdtempSync(join(tmpdir(), 'partial-scan-a-'));
  sourceB = mkdtempSync(join(tmpdir(), 'partial-scan-b-'));
  sourceC = mkdtempSync(join(tmpdir(), 'partial-scan-c-'));
  for (const dir of [sourceA, sourceB, sourceC]) {
    mkdirSync(join(dir, 'people'), { recursive: true });
    for (let i = 0; i < 5; i++) {
      writeFileSync(
        join(dir, 'people', `p${i}.md`),
        `---\ntitle: Person ${i}\n---\n\nbody\n`,
      );
    }
  }
});

afterAll(async () => {
  await engine.disconnect();
  for (const d of [sourceA, sourceB, sourceC]) {
    rmSync(d, { recursive: true, force: true });
  }
});

beforeEach(async () => {
  await resetPgliteState(engine);
  // Register all three sources for each test.
  await engine.executeRaw(
    `INSERT INTO sources (id, name, local_path) VALUES ('src-a', 'A', $1), ('src-b', 'B', $2), ('src-c', 'C', $3)`,
    [sourceA, sourceB, sourceC],
  );
});

describe('scanBrainSources partial-scan state', () => {
  test('no deadline + no abort: every source scanned, partial=false, ok reflects grandTotal', async () => {
    const report = await scanBrainSources(engine);
    expect(report.partial).toBe(false);
    expect(report.aborted_at_source).toBe(null);
    expect(report.per_source.length).toBe(3);
    for (const src of report.per_source) {
      expect(src.status).toBe('scanned');
      expect(src.files_scanned).toBe(5);
    }
    expect(report.total).toBe(0);
    expect(report.ok).toBe(true);
  });

  test('deadline expired before any source starts: all three skipped', async () => {
    const report = await scanBrainSources(engine, {
      deadline: Date.now() - 1, // already expired
    });
    expect(report.partial).toBe(true);
    expect(report.per_source.length).toBe(3);
    for (const src of report.per_source) {
      expect(src.status).toBe('skipped');
      expect(src.files_scanned).toBe(0);
    }
    // ok must be false even though zero errors were found — partial state
    // means the clean count can't speak for unscanned files (codex C2).
    expect(report.ok).toBe(false);
  });

  test('after-abort ok field is false even on clean prefix (codex C2 regression guard)', async () => {
    // Force the abort path: deadline already expired. Even though no
    // errors found (because no files scanned), `ok` must reflect the
    // partial-scan reality.
    const report = await scanBrainSources(engine, {
      deadline: Date.now() - 1,
    });
    expect(report.total).toBe(0);
    expect(report.partial).toBe(true);
    expect(report.ok).toBe(false);
  });

  test('files_scanned numerator populated on completed sources (codex C4 regression guard)', async () => {
    const report = await scanBrainSources(engine);
    for (const src of report.per_source) {
      // Each source has 5 .md files under people/; all syncable.
      expect(src.files_scanned).toBe(5);
    }
  });

  test('dbPageCountForSource hook plumbed onto db_page_count; failure degrades to null', async () => {
    let calls = 0;
    const report = await scanBrainSources(engine, {
      dbPageCountForSource: async (sourceId) => {
        calls++;
        if (sourceId === 'src-b') throw new Error('synthetic query failure');
        return sourceId === 'src-a' ? 42 : 99;
      },
    });
    expect(calls).toBe(3);
    const a = report.per_source.find(r => r.source_id === 'src-a')!;
    const b = report.per_source.find(r => r.source_id === 'src-b')!;
    const c = report.per_source.find(r => r.source_id === 'src-c')!;
    expect(a.db_page_count).toBe(42);
    // Throw → null, no crash, scan continues.
    expect(b.db_page_count).toBe(null);
    expect(c.db_page_count).toBe(99);
    // files_scanned numerator still populated regardless of denominator outcome.
    expect(b.files_scanned).toBe(5);
  });
});
