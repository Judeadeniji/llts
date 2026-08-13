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
			buffer.free(buf);
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
			buffer.free(buf);
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
			buffer.free(buf);
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
			buffer.free(buf);
			buffer.free(buf2);
		}
	`);
	expectOutput(res, ["5", "world"]);
});

test("buffer: out of bounds", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$buf = buffer.alloc(5);
			print(buffer.get(buf, 10));
		}
	`);
	expectOutput(res, ["Error: Buffer read out of bounds"]);
});
