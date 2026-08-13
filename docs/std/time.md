# `time`

The `time` standard library module provides functionality for measuring time, working with durations, and pausing execution. Both absolute time (timestamps) and durations are represented internally as Unix/span nanoseconds (using floats or integers).

## Constants

The module provides constants representing duration units in nanoseconds:

*   `Nanosecond`: 1
*   `Microsecond`: 1,000
*   `Millisecond`: 1,000,000
*   `Second`: 1,000,000,000
*   `Minute`: 60,000,000,000
*   `Hour`: 3,600,000,000,000

*Usage Example:*
```llts
$timeout = 5 * time.Second;
```

## Clock

Functions for checking the current time and sleeping. The underlying clock uses Unix timestamps in nanoseconds (`__now()` built-in calling `std.time.nanoTimestamp()` natively).

### `Now()`
Returns the current time as a Unix timestamp in nanoseconds.

### `Sleep(d)`
Pauses the current execution thread for the duration `d` (in nanoseconds).

### `Since(t)`
Returns the duration elapsed since the time `t`. Equivalent to `Now() - t`.

### `Until(t)`
Returns the duration until the time `t`. Equivalent to `t - Now()`.

## Time Constructors

Functions for constructing a Unix timestamp in nanoseconds from other units.

### `Unix(sec, nsec)`
Returns the Unix time in nanoseconds, calculated from `sec` seconds and `nsec` nanoseconds.

### `UnixMilli(msec)`
Returns the Unix time in nanoseconds from `msec` milliseconds.

### `UnixNano(nsec)`
Returns the Unix time in nanoseconds from `nsec` nanoseconds.

## Time Arithmetic and Comparison

### `Add(t, d)`
Adds duration `d` to time `t`. Returns `t + d`.

### `Sub(t, u)`
Subtracts time `u` from time `t`, returning the duration between them (`t - u`).

### `Before(t, u)`
Returns `true` if time `t` is before time `u` (`t < u`).

### `After(t, u)`
Returns `true` if time `t` is after time `u` (`t > u`).

### `Equal(t, u)`
Returns `true` if time `t` is equal to time `u` (`t == u`).

### `IsZero(t)`
Returns `true` if time `t` is exactly `0`.

## Duration Conversions

These functions convert a duration `d` (in nanoseconds) into other time units. They can also be used to convert a timestamp into the respective Unix epoch unit.

### `Nanoseconds(d)`
Returns `d` as nanoseconds.

### `Microseconds(d)`
Returns `d` as microseconds (`d / 1000`).

### `Milliseconds(d)`
Returns `d` as milliseconds (`d / 1000000`).

### `Seconds(d)`
Returns `d` as seconds (`d / 1000000000`).

### `Minutes(d)`
Returns `d` as minutes.

### `Hours(d)`
Returns `d` as hours.

## Examples

**Measuring Elapsed Time:**
```llts
$start = time.Now();

# Do some work...
time.Sleep(150 * time.Millisecond);

$elapsed = time.Since(start);
$elapsed_ms = time.Milliseconds(elapsed);
```

**Working with Future Time:**
```llts
$deadline = time.Add(time.Now(), 2 * time.Hour);

if (time.Before(time.Now(), deadline)) {
    # Still have time left
    $remaining = time.Until(deadline);
    $remaining_mins = time.Minutes(remaining);
}
```
