// 100k function-call benchmark (Bun / JS).
// Use: bun benchmarks/call_100k.js

const N = 100_000;

function add(a, b) {
  return a + b;
}

let sum = 0;
const start = performance.now();

for (let i = 0; i < N; i++) {
  sum = add(sum, i);
}

const elapsed_ms = performance.now() - start;
console.log(`bun-call: ${elapsed_ms.toFixed(3)} ms sum= ${sum}`);
