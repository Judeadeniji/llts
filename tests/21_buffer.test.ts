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
	expectError(res, "error.IndexOutOfBounds");
});

test("buffer: out of bounds get", () => {
	const res = runSource(`
		@const $buffer = @import("std/buffer");
		pub @func main() {
			$buf = buffer.alloc(5);
			print(buffer.get(buf, 10));
		}
	`);
	expectError(res, "error.IndexOutOfBounds");
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
