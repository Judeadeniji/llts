#!/usr/bin/env bun
/**
 * Before/after benchmark harness for llts-zig VM optimizations.
 *
 * Usage:
 *   # Step 1 – capture BEFORE baseline (run this BEFORE applying any changes):
 *   bun benchmarks/bench.ts --phase before [--runs 5]
 *
 *   # Step 2 – apply your optimizations, then capture AFTER:
 *   bun benchmarks/bench.ts --phase after  [--runs 5]
 *
 *   # Print a diff between the two saved results:
 *   bun benchmarks/bench.ts --phase report
 *
 *   # Run a single quick pass (no save):
 *   bun benchmarks/bench.ts [--runs 3]
 */

import { $ } from "bun";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const lltsBin = resolve(root, "zig-out/bin/llts");
const resultsDir = resolve(root, "benchmarks/results");
const RESULTS_FILE = (phase: string) => resolve(resultsDir, `${phase}.json`);

// ── CLI args ──────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const phase = (() => {
  const i = argv.indexOf("--phase");
  return i >= 0 ? argv[i + 1] : undefined;
})();
const runs = (() => {
  const i = argv.indexOf("--runs");
  return i >= 0 ? Math.max(1, Number(argv[i + 1])) : 5;
})();
const noBuild = argv.includes("--no-build");

// ── Benchmark definitions ─────────────────────────────────────────────────────
interface BenchDef {
  id: string;
  label: string;
  llts: string;   // path to .lls file
  js?: string;    // path to .js counterpart (optional)
  // regex to parse "name: 12.345 ms ..." from stdout
  pattern: RegExp;
}

const BENCHES: BenchDef[] = [
  {
    id: "loop_1m",
    label: "1M integer loop",
    llts: "benchmarks/loop_1m.lls",
    js: "benchmarks/loop_1m.js",
    pattern: /(?:llts|bun):\s+([\d.]+)\s+ms/,
  },
  {
    id: "call_100k",
    label: "100k function calls",
    llts: "benchmarks/call_100k.lls",
    js: "benchmarks/call_100k.js",
    pattern: /(?:llts-call|bun-call):\s+([\d.]+)\s+ms/,
  },
  {
    id: "arith_1m",
    label: "1M mixed arithmetic",
    llts: "benchmarks/arith_1m.lls",
    js: "benchmarks/arith_1m.js",
    pattern: /(?:llts-arith|bun-arith):\s+([\d.]+)\s+ms/,
  },
];

// ── Helpers ───────────────────────────────────────────────────────────────────
function parseMs(stdout: string, pat: RegExp): number | null {
  const m = stdout.match(pat);
  return m ? Number(m[1]) : null;
}

interface Stats {
  min: number;
  max: number;
  mean: number;
  median: number;
  samples: number[];
}

function stats(xs: number[]): Stats {
  const sorted = [...xs].sort((a, b) => a - b);
  return {
    min: sorted[0]!,
    max: sorted[sorted.length - 1]!,
    mean: xs.reduce((a, b) => a + b, 0) / xs.length,
    median: sorted[Math.floor(sorted.length / 2)]!,
    samples: xs,
  };
}

async function runProcess(cmd: string[], cwd: string): Promise<string> {
  const proc = Bun.spawn(cmd, { cwd, stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code !== 0) throw new Error(`Exit ${code}: ${err || out}`);
  return out;
}

async function buildLlts() {
  console.log("Building llts (ReleaseFast)...");
  await $`zig build -Doptimize=ReleaseFast`.cwd(root);
  if (!(await Bun.file(lltsBin).exists()))
    throw new Error(`Binary missing at ${lltsBin}`);
}

// ── Single benchmark run ──────────────────────────────────────────────────────
interface BenchResult {
  id: string;
  label: string;
  llts: Stats;
  js?: Stats;
}

async function runBench(def: BenchDef, n: number): Promise<BenchResult> {
  const lltsMs: number[] = [];
  const jsMs: number[] = [];

  // warmup
  await runProcess([lltsBin, "run", "--release", def.llts], root);
  if (def.js) await runProcess(["bun", def.js], root);

  for (let i = 0; i < n; i++) {
    const out = await runProcess([lltsBin, "run", "--release", def.llts], root);
    const ms = parseMs(out, def.pattern);
    if (ms == null) throw new Error(`Could not parse llts output:\n${out}`);
    lltsMs.push(ms);

    if (def.js) {
      const jsOut = await runProcess(["bun", def.js], root);
      const jms = parseMs(jsOut, def.pattern);
      if (jms == null) throw new Error(`Could not parse bun output:\n${jsOut}`);
      jsMs.push(jms);
    }

    process.stdout.write(`  [${def.id}] run ${i + 1}/${n}  llts=${lltsMs[i]!.toFixed(2)}ms`);
    if (def.js) process.stdout.write(`  bun=${jsMs[i]!.toFixed(2)}ms`);
    process.stdout.write("\n");
  }

  return {
    id: def.id,
    label: def.label,
    llts: stats(lltsMs),
    ...(def.js ? { js: stats(jsMs) } : {}),
  };
}

// ── Report ────────────────────────────────────────────────────────────────────
function fmt(n: number) { return n.toFixed(3); }

function printResult(r: BenchResult) {
  console.log(`\n  ${r.label}`);
  console.log(`    llts  median=${fmt(r.llts.median)} mean=${fmt(r.llts.mean)} min=${fmt(r.llts.min)} max=${fmt(r.llts.max)} ms`);
  if (r.js) {
    const ratio = r.llts.median / r.js.median;
    console.log(`    bun   median=${fmt(r.js.median)} mean=${fmt(r.js.mean)} min=${fmt(r.js.min)} max=${fmt(r.js.max)} ms`);
    console.log(`    ratio llts/bun = ${ratio.toFixed(2)}×  (${ratio > 1 ? `llts is ${ratio.toFixed(2)}× slower` : `llts is ${(1/ratio).toFixed(2)}× faster`})`);
  }
}

function printComparison(before: BenchResult[], after: BenchResult[]) {
  console.log("\n╔══════════════════════════════════════════════════════════╗");
  console.log("║            BEFORE vs AFTER (median ms, llts only)       ║");
  console.log("╠══════════════════════════════════════════════════════════╣");

  for (const b of before) {
    const a = after.find(x => x.id === b.id);
    if (!a) continue;
    const delta = a.llts.median - b.llts.median;
    const pct = (delta / b.llts.median) * 100;
    const sign = delta < 0 ? "▼" : delta > 0 ? "▲" : "─";
    const speedup = b.llts.median / a.llts.median;
    console.log(`║  ${b.label.padEnd(24)}  before=${fmt(b.llts.median).padStart(8)}ms  after=${fmt(a.llts.median).padStart(8)}ms  ${sign} ${Math.abs(pct).toFixed(1).padStart(5)}%  (${speedup.toFixed(2)}× speedup)`);
  }
  console.log("╚══════════════════════════════════════════════════════════╝");
}

// ── Entry point ───────────────────────────────────────────────────────────────
await Bun.write(resolve(resultsDir, ".gitkeep"), "").catch(() => {});

if (phase === "report") {
  const bf = Bun.file(RESULTS_FILE("before"));
  const af = Bun.file(RESULTS_FILE("after"));
  if (!(await bf.exists()) || !(await af.exists())) {
    console.error("Run --phase before and --phase after first.");
    process.exit(1);
  }
  const before: BenchResult[] = await bf.json();
  const after: BenchResult[] = await af.json();
  console.log("\n=== BEFORE ===");
  before.forEach(printResult);
  console.log("\n=== AFTER ===");
  after.forEach(printResult);
  printComparison(before, after);
  process.exit(0);
}

// Run suite
if (noBuild) {
  console.log("Skipping build (--no-build). Using existing binary.");
  if (!(await Bun.file(lltsBin).exists()))
    throw new Error(`Binary missing at ${lltsBin} — build first.`);
} else {
  await buildLlts();
}
console.log(`\nRunning ${BENCHES.length} benchmarks × ${runs} runs each...\n`);

const results: BenchResult[] = [];
for (const def of BENCHES) {
  console.log(`► ${def.label}`);
  results.push(await runBench(def, runs));
}

console.log("\n=== Results ===");
results.forEach(printResult);

if (phase === "before" || phase === "after") {
  const path = RESULTS_FILE(phase);
  await Bun.write(path, JSON.stringify(results, null, 2));
  console.log(`\n✔ Saved ${phase} results → ${path}`);
  if (phase === "before") {
    console.log("  Apply your optimizations, then run: bun benchmarks/bench.ts --phase after");
    console.log("  Then compare with:                  bun benchmarks/bench.ts --phase report");
  } else {
    console.log("  Compare now with: bun benchmarks/bench.ts --phase report");
  }
}
