// 1M integer loop benchmark (Bun / JS).
// Times only the loop body; use: bun benchmarks/loop_1m.js

const N = 1_000_000;

let sum = 0;
const start = performance.now();

for (let i = 0; i < N; i++) {
  sum = sum + i;
}

const elapsed_ms = performance.now() - start;

console.log(`bun: ${elapsed_ms.toFixed(3)} ms sum= ${sum}`);
