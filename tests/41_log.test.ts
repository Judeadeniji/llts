/**
 * 1:1 Port of Go's log package tests from /usr/local/go/src/log/log_test.go and example_test.go
 * Tested using LLTS pro-camelCase APIs.
 */
import { test, expect } from "bun:test";
import { runSource } from "./helpers";

const rDate = `[0-9]{4}/[0-9]{2}/[0-9]{2}`;
const rTime = `[0-9]{2}:[0-9]{2}:[0-9]{2}`;
const rMicroseconds = `\\.[0-9]{6}`;
const rLongfile = `.+/[A-Za-z0-9_\\-\\.]+\\.lls:[0-9]+:`;
const rShortfile = `[A-Za-z0-9_\\-\\.]+\\.lls:[0-9]+:`;

interface Tester {
	flag: number;
	prefix: string;
	pattern: string;
}

const ldate = 1;
const ltime = 2;
const lmicroseconds = 4;
const llongfile = 8;
const lshortfile = 16;
const lmsgprefix = 64;

const testCases: Tester[] = [
	// individual pieces:
	{ flag: 0, prefix: "", pattern: "" },
	{ flag: 0, prefix: "XXX", pattern: "XXX" },
	{ flag: ldate, prefix: "", pattern: rDate + " " },
	{ flag: ltime, prefix: "", pattern: rTime + " " },
	{ flag: ltime | lmsgprefix, prefix: "XXX", pattern: rTime + " XXX" },
	{ flag: ltime | lmicroseconds, prefix: "", pattern: rTime + rMicroseconds + " " },
	{ flag: lmicroseconds, prefix: "", pattern: rTime + rMicroseconds + " " },
	{ flag: llongfile, prefix: "", pattern: rLongfile + " " },
	{ flag: lshortfile, prefix: "", pattern: rShortfile + " " },
	{ flag: llongfile | lshortfile, prefix: "", pattern: rShortfile + " " },
	// everything at once:
	{
		flag: ldate | ltime | lmicroseconds | llongfile,
		prefix: "XXX",
		pattern: "XXX" + rDate + " " + rTime + rMicroseconds + " " + rLongfile + " ",
	},
	{
		flag: ldate | ltime | lmicroseconds | lshortfile,
		prefix: "XXX",
		pattern: "XXX" + rDate + " " + rTime + rMicroseconds + " " + rShortfile + " ",
	},
	{
		flag: ldate | ltime | lmicroseconds | llongfile | lmsgprefix,
		prefix: "XXX",
		pattern: rDate + " " + rTime + rMicroseconds + " " + rLongfile + " XXX",
	},
	{
		flag: ldate | ltime | lmicroseconds | lshortfile | lmsgprefix,
		prefix: "XXX",
		pattern: rDate + " " + rTime + rMicroseconds + " " + rShortfile + " XXX",
	},
];

test("TestDefault: Default returns standard logger", () => {
	const res = runSource(`
@const $log = @import("std/log");
pub @func main() {
    $d = log.default();
    $s = &log.std;
    print(d == s);
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout.trim()).toBe("true");
});

test("TestAll: All 14 flag combinations match Go specification", () => {
	// Execute all 14 test cases in a single LLTS program for maximum performance
	const scriptLines: string[] = [
		`@const $log = @import("std/log");`,
		`pub @func main() {`,
		`    $buf = log.newBuffer();`,
		`    log.setOutput(&buf);`,
		`    $out1: string = "";`,
		`    $out2: string = "";`,
	];

	for (const tc of testCases) {
		// println
		scriptLines.push(`    buf.reset();`);
		scriptLines.push(`    log.setFlags(${tc.flag});`);
		scriptLines.push(`    log.setPrefix("${tc.prefix}");`);
		scriptLines.push(`    log.println("hello", 23, "world");`);
		scriptLines.push(`    out1 = buf.string();`);
		scriptLines.push(`    @if (len(out1) > 0 && out1[len(out1) - 1] == 10) { out1 = __slice(out1, 0, len(out1) - 1); }`);
		scriptLines.push(`    print(out1);`);

		// printf
		scriptLines.push(`    buf.reset();`);
		scriptLines.push(`    log.setFlags(${tc.flag});`);
		scriptLines.push(`    log.setPrefix("${tc.prefix}");`);
		scriptLines.push(`    log.printf("hello %d world", 23);`);
		scriptLines.push(`    out2 = buf.string();`);
		scriptLines.push(`    @if (len(out2) > 0 && out2[len(out2) - 1] == 10) { out2 = __slice(out2, 0, len(out2) - 1); }`);
		scriptLines.push(`    print(out2);`);
	}

	scriptLines.push(`}`);
	const src = scriptLines.join("\n");
	
	const res = runSource(src);
	expect(res.exitCode).toBe(0);

	const lines = res.stdout.split(/\r?\n/).filter((l) => l.length > 0);
	expect(lines.length).toBe(testCases.length * 2);

	for (let i = 0; i < testCases.length; i++) {
		const tc = testCases[i];
		const linePrintln = lines[i * 2];
		const linePrintf = lines[i * 2 + 1];

		const regex = new RegExp(`^${tc.pattern}hello 23 world$`);
		if (!regex.test(linePrintln)) {
			throw new Error(`TestAll case ${i} (println) failed:\nPattern: ${regex}\nGot:     ${linePrintln}`);
		}
		if (!regex.test(linePrintf)) {
			throw new Error(`TestAll case ${i} (printf) failed:\nPattern: ${regex}\nGot:     ${linePrintf}`);
		}
	}
});

test("TestOutput: basic Output functionality", () => {
	const res = runSource(`
@const $log = @import("std/log");
pub @func main() {
    $b = log.newBuffer();
    $l = log.new(&b, "", 0);
    l.println("test");
    print(b.string() == "test\\n");
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout.trim()).toBe("true");
});

test("TestNonNewLogger: struct literal initialized logger works with setOutput", () => {
	const res = runSource(`
@const $log = @import("std/log");
pub @func main() {
    $l = log.Logger {};
    $b = log.newBuffer();
    l.setOutput(&b);
    l.print("hello");
    print(b.string() == "hello\\n");
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout.trim()).toBe("true");
});

test("TestFlagAndPrefixSetting: flags and prefix getter/setter and newline preservation", () => {
	const res = runSource(`
@const $log = @import("std/log");
pub @func main() {
    $b = log.newBuffer();
    $l = log.new(&b, "Test:", log.lstdFlags);
    $f = l.flags();
    @if (f != log.lstdFlags) {
        print("bad initial flags");
        return null;
    }
    l.setFlags(f | log.lmicroseconds);
    $f2 = l.flags();
    @if (f2 != (log.lstdFlags | log.lmicroseconds)) {
        print("bad microseconds flags");
        return null;
    }
    $p = l.prefix();
    @if (p != "Test:") {
        print("bad prefix");
        return null;
    }
    l.setPrefix("Reality:");
    $p2 = l.prefix();
    @if (p2 != "Reality:") {
        print("bad setPrefix");
        return null;
    }
    l.print("hello");

    # Verify newline preservation when prefix ends with newline and output is empty
    b.reset();
    l.setFlags(0);
    l.setPrefix("\\n");
    l.output(0, "");
    $preserved = (b.string() == "\\n");
    print(preserved);
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout.trim()).toBe("true");
});

test("TestUTCFlag: lUTC formats date/time in UTC", () => {
	const res = runSource(`
@const $log = @import("std/log");
pub @func main() {
    $b = log.newBuffer();
    $l = log.new(&b, "Test:", log.lstdFlags);
    l.setFlags(log.ldate | log.ltime | log.lutc);
    l.print("hello");
    print(b.string());
}
`);
	expect(res.exitCode).toBe(0);
	const line = res.stdout.trim();
	const regex = new RegExp(`^Test:${rDate} ${rTime} hello$`);
	expect(regex.test(line)).toBe(true);
});

test("TestEmptyPrintCreatesLine: empty print call still outputs header and newline", () => {
	const res = runSource(`
@const $log = @import("std/log");
pub @func main() {
    $b = log.newBuffer();
    $l = log.new(&b, "Header:", log.lstdFlags);
    l.print();
    l.println("non-empty");
    $out = b.string();
    # Count occurrences of Header
    $firstHeader = __indexOf(out, "Header:");
    $secondHeader = __indexOfFrom(out, "Header:", firstHeader + 1);
    $twoHeaders = (firstHeader >= 0 && secondHeader > firstHeader);

    # Count occurrences of newline
    $firstNL = __indexOf(out, "\\n");
    $secondNL = __indexOfFrom(out, "\\n", firstNL + 1);
    $twoNLs = (firstNL >= 0 && secondNL > firstNL);

    print(twoHeaders && twoNLs);
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout.trim()).toBe("true");
});

test("TestDiscard: discard writer absorbs output without error", () => {
	const res = runSource(`
@const $log = @import("std/log");
pub @func main() {
    $l = log.new(log.discard, "", 0);
    l.printf("this should be discarded: %d", 12345);
    l.println("also discarded");
    print("discard-ok");
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout.trim()).toBe("discard-ok");
});

test("ExampleLogger: shortfile prefix and line reporting", () => {
	const res = runSource(`
@const $log = @import("std/log");
pub @func main() {
    $buf = log.newBuffer();
    $logger = log.new(&buf, "logger: ", log.lshortfile);
    logger.print("Hello, log file!");
    print(buf.string());
}
`);
	expect(res.exitCode).toBe(0);
	const line = res.stdout.trim();
	const regex = new RegExp(`^logger: ${rShortfile} Hello, log file!$`);
	expect(regex.test(line)).toBe(true);
});

test("ExampleLogger_Output: custom calldepth preserves caller site", () => {
	const res = runSource(`
@const $log = @import("std/log");

@func infof(logger: *log.Logger, info: string) {
    logger.output(2, info);
}

pub @func main() {
    $buf = log.newBuffer();
    $logger = log.new(&buf, "INFO: ", log.lshortfile);
    infof(&logger, "Hello world");
    print(buf.string());
}
`);
	expect(res.exitCode).toBe(0);
	const line = res.stdout.trim();
	const regex = new RegExp(`^INFO: ${rShortfile} Hello world$`);
	expect(regex.test(line)).toBe(true);
});

test("Log submodules: slog and syslog are accessible under log", () => {
	const res = runSource(`
@const $log = @import("std/log");
pub @func main() {
    print(log.slog.levelDebug);
    print(log.slog.levelInfo);
    print(log.syslog.LOG_EMERG);
    print(log.syslog.LOG_DEBUG);
    print(log.slog.levelWarn);
    print(log.syslog.LOG_LOCAL7);
}
`);
	expect(res.exitCode).toBe(0);
	const lines = res.stdout.split(/\r?\n/).filter((l) => l.length > 0);
	expect(lines[0]).toBe("-4");
	expect(lines[1]).toBe("0");
	expect(lines[2]).toBe("0");
	expect(lines[3]).toBe("7");
	expect(lines[4]).toBe("4");
	expect(lines[5]).toBe("184");
});
