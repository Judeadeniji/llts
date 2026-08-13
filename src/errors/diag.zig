//! Tracks whether a rich diagnostic was already printed so CLI exit
//! can avoid a duplicate `Error: RuntimeError` line.

var emitted: bool = false;

pub fn markEmitted() void {
    emitted = true;
}

pub fn wasEmitted() bool {
    return emitted;
}

pub fn reset() void {
    emitted = false;
}
