// 1M mixed-arithmetic benchmark (Bun / JS).
// Use: bun benchmarks/arith_1m.js

const N = 1_000_000;

let acc = 1;
const start = performance.now();

for (let i = 0; i < N; i++) {
  acc = acc + i;
  acc = acc * 2;
  acc = acc - i;
  acc = acc / 2;
}

const elapsed_ms = performance.now() - start;
console.log(`bun-arith: ${elapsed_ms.toFixed(3)} ms acc= ${acc}`);
