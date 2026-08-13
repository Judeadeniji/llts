import { test, expect } from "bun:test";
import { runSource, expectOutput, expectError } from "./helpers";

test("buffer: alloc, len, get, set", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$buf = buffer.alloc(10);
			print(buffer.len(buf));
			buffer.set(buf, 0, 65);
			buffer.set(buf, 1, 66);
			print(buffer.get(buf, 0));
			print(buffer.get(buf, 1));
		}
	`);
	expectOutput(res, ["10", "65", "66"]);
});

test("buffer: dynamic growth", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$buf = buffer.create();
			buffer.push(buf, 72);
			buffer.appendString(buf, "ello");
			print(buffer.len(buf));
			print(buffer.readString(buf, 0, buffer.len(buf)));
		}
	`);
	expectOutput(res, ["5", "Hello"]);
});

test("buffer: string I/O", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$buf = buffer.alloc(100);
			$len = buffer.writeString(buf, 5, "Hello");
			print(len);
			print(buffer.readString(buf, 5, 5));
		}
	`);
	expectOutput(res, ["5", "Hello"]);
});

test("buffer: file I/O", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		@const $fs = @import("std/fs");
		pub @func main() {
			$buf = buffer.alloc(5);
			buffer.writeString(buf, 0, "world");
			fs.writeFileBuffer("test_buf.txt", buf);
			
			$buf2 = fs.readFileBuffer("test_buf.txt");
			print(buffer.len(buf2));
			print(buffer.readString(buf2, 0, 5));
			
			fs.deleteFile("test_buf.txt");
		}
	`);
	expectOutput(res, ["5", "world"]);
});

test("buffer: out of bounds write/set", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$buf = buffer.alloc(5);
			buffer.set(buf, 10, 255);
		}
	`);
	expectError(res, "IndexOutOfBounds");
});

test("buffer: out of bounds get", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$buf = buffer.alloc(5);
			print(buffer.get(buf, 10));
		}
	`);
	expectError(res, "IndexOutOfBounds");
});

test("buffer: resize, copy, fill, fromString", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$b1 = buffer.fromString("hello");
			print(buffer.len(b1));
			
			buffer.resize(b1, 10);
			print(buffer.len(b1));
			print(buffer.get(b1, 8)); # should be 0
			
			buffer.fill(b1, 33); # fill with '!'
			print(buffer.readString(b1, 0, 10)); # !!!!!!!!!!
			
			$b2 = buffer.alloc(5);
			buffer.copy(b2, 0, b1, 2, 5);
			print(buffer.readString(b2, 0, 5)); # !!!!!
		}
	`);
	expectOutput(res, ["5", "10", "0", "!!!!!!!!!!", "!!!!!"]);
});

test("buffer: edge cases", () => {
	// Negative alloc
	expectError(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() { buffer.alloc(-1); }
	`), "IndexOutOfBounds");

	// Negative resize
	expectError(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() { $b = buffer.alloc(5); buffer.resize(b, -5); }
	`), "IndexOutOfBounds");

	// readString zero length
	expectOutput(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() { $b = buffer.alloc(5); print(len(buffer.readString(b, 0, 0))); }
	`), ["0"]);

	// readString out of bounds
	expectError(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() { $b = buffer.alloc(5); buffer.readString(b, 4, 2); }
	`), "IndexOutOfBounds");

	// writeString out of bounds
	expectError(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() { $b = buffer.alloc(5); buffer.writeString(b, 4, "hi"); }
	`), "IndexOutOfBounds");

	// writeString empty string
	expectOutput(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() { $b = buffer.alloc(5); print(buffer.writeString(b, 0, "")); }
	`), ["0"]);

	// copy out of bounds
	expectError(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() { 
			$b1 = buffer.alloc(5); 
			$b2 = buffer.alloc(5); 
			buffer.copy(b1, 0, b2, 4, 2); 
		}
	`), "IndexOutOfBounds");
});

test("buffer: overlapping copy", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$b = buffer.fromString("12345678");
			# copy "1234" to offset 2 -> "12123478" (copyBackwards)
			buffer.copy(b, 2, b, 0, 4);
			print(buffer.readString(b, 0, 8));
			
			$b2 = buffer.fromString("12345678");
			# copy "3456" to offset 0 -> "34565678" (copyForwards)
			buffer.copy(b2, 0, b2, 2, 4);
			print(buffer.readString(b2, 0, 8));

			$b3 = buffer.fromString("12345678");
			# copy to same offset -> no-op
			buffer.copy(b3, 2, b3, 2, 4);
			print(buffer.readString(b3, 0, 8));
		}
	`);
	expectOutput(res, ["12123478", "34565678", "12345678"]);
});

test("buffer: fillRange", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$b = buffer.fromString("12345678");
			buffer.fillRange(b, 33, 2, 4); # replace 4 bytes starting at 2 with '!'
			print(buffer.readString(b, 0, 8));
		}
	`);
	expectOutput(res, ["12!!!!78"]);
});

test("buffer: additional edge cases", () => {
	// fillRange OOB
	expectError(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() { $b = buffer.alloc(5); buffer.fillRange(b, 33, 4, 2); }
	`), "IndexOutOfBounds");

	// resize shrink
	expectOutput(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$b = buffer.fromString("12345678");
			buffer.resize(b, 4);
			print(buffer.len(b));
			print(buffer.readString(b, 0, 4));
		}
	`), ["4", "1234"]);

	// alloc(0)
	expectOutput(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$b = buffer.alloc(0);
			print(buffer.len(b));
		}
	`), ["0"]);

	// set byte mask
	expectOutput(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$b = buffer.alloc(1);
			buffer.set(b, 0, 300);
			print(buffer.get(b, 0));
		}
	`), ["44"]);

	// Type error (pass int where buffer expected)
	expectError(runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() { buffer.len(123); }
	`), "TypeError");
});
