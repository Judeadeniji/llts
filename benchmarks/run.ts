#!/usr/bin/env bun
/**
 * Compare Bun vs LLTS on a 1M integer accumulation loop.
 * Measures loop body time (printed by each program) and wall-clock process time.
 *
 * Usage:
 *   bun benchmarks/run.ts
 *   bun benchmarks/run.ts --runs 5
 */

import { $ } from "bun";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const lltsBin = resolve(root, "zig-out/bin/llts");
const lltsSrc = resolve(root, "benchmarks/loop_1m.lls");
const bunSrc = resolve(root, "benchmarks/loop_1m.js");

const runs = (() => {
  const i = process.argv.indexOf("--runs");
  if (i >= 0 && process.argv[i + 1]) return Math.max(1, Number(process.argv[i + 1]));
  return 3;
})();

function parseMs(stdout: string): number | null {
  // "llts: 12.5 ms sum= …" or "bun: 8.257 ms sum= …"
  const m = stdout.match(/(?:llts|bun):\s+([\d.]+)\s+ms/);
  return m ? Number(m[1]) : null;
}

function stats(xs: number[]) {
  const sorted = [...xs].sort((a, b) => a - b);
  const sum = xs.reduce((a, b) => a + b, 0);
  return {
    min: sorted[0]!,
    max: sorted[sorted.length - 1]!,
    mean: sum / xs.length,
    median: sorted[Math.floor(sorted.length / 2)]!,
  };
}

async function ensureLlts() {
  const exists = await Bun.file(lltsBin).exists();
  if (exists) return;
  console.log("Building llts (ReleaseFast)...");
  await $`zig build -Doptimize=ReleaseFast`.cwd(root);
  if (!(await Bun.file(lltsBin).exists())) {
    throw new Error(`llts binary missing at ${lltsBin}; run: zig build`);
  }
}

type Sample = { loopMs: number; wallMs: number; stdout: string };

async function runLlts(): Promise<Sample> {
  const wallStart = performance.now();
  const proc = Bun.spawn([lltsBin, "run", "--release", lltsSrc], {
    cwd: root,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  const wallMs = performance.now() - wallStart;
  if (exitCode !== 0) {
    throw new Error(`llts exited ${exitCode}\n${stderr || stdout}`);
  }
  const loopMs = parseMs(stdout);
  if (loopMs == null) throw new Error(`could not parse llts timing from:\n${stdout}`);
  return { loopMs, wallMs, stdout: stdout.trim() };
}

async function runBun(): Promise<Sample> {
  const wallStart = performance.now();
  const proc = Bun.spawn(["bun", bunSrc], {
    cwd: root,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  const wallMs = performance.now() - wallStart;
  if (exitCode !== 0) {
    throw new Error(`bun exited ${exitCode}\n${stderr || stdout}`);
  }
  const loopMs = parseMs(stdout);
  if (loopMs == null) throw new Error(`could not parse bun timing from:\n${stdout}`);
  return { loopMs, wallMs, stdout: stdout.trim() };
}

await ensureLlts();

console.log(`1M loop benchmark — ${runs} run(s) each\n`);

const bunSamples: Sample[] = [];
const lltsSamples: Sample[] = [];

// Warmup (discarded)
await runBun();
await runLlts();

for (let i = 0; i < runs; i++) {
  const bun = await runBun();
  const llts = await runLlts();
  bunSamples.push(bun);
  lltsSamples.push(llts);
  console.log(`run ${i + 1}/${runs}`);
  console.log(`  ${bun.stdout}  (wall ${bun.wallMs.toFixed(1)} ms)`);
  console.log(`  ${llts.stdout}  (wall ${llts.wallMs.toFixed(1)} ms)`);
}

const bunLoop = stats(bunSamples.map((s) => s.loopMs));
const lltsLoop = stats(lltsSamples.map((s) => s.loopMs));
const bunWall = stats(bunSamples.map((s) => s.wallMs));
const lltsWall = stats(lltsSamples.map((s) => s.wallMs));

console.log("\n--- loop body (ms) ---");
console.log(
  `bun:  median ${bunLoop.median.toFixed(3)}  mean ${bunLoop.mean.toFixed(3)}  min ${bunLoop.min.toFixed(3)}  max ${bunLoop.max.toFixed(3)}`,
);
console.log(
  `llts: median ${lltsLoop.median.toFixed(3)}  mean ${lltsLoop.mean.toFixed(3)}  min ${lltsLoop.min.toFixed(3)}  max ${lltsLoop.max.toFixed(3)}`,
);

console.log("\n--- process wall (ms, includes compile+startup) ---");
console.log(
  `bun:  median ${bunWall.median.toFixed(1)}  mean ${bunWall.mean.toFixed(1)}`,
);
console.log(
  `llts: median ${lltsWall.median.toFixed(1)}  mean ${lltsWall.mean.toFixed(1)}`,
);

const ratio = lltsLoop.median / bunLoop.median;
const winner = bunLoop.median <= lltsLoop.median ? "bun" : "llts";
const loser = winner === "bun" ? "llts" : "bun";
const winMs = winner === "bun" ? bunLoop.median : lltsLoop.median;
const loseMs = winner === "bun" ? lltsLoop.median : bunLoop.median;
console.log(
  `\nWinner (loop body): ${winner} — ${loseMs.toFixed(3)} / ${winMs.toFixed(3)} ≈ ${ratio >= 1 ? ratio.toFixed(2) : (1 / ratio).toFixed(2)}× faster than ${loser}`,
);
