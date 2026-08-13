# Math Standard Library (`std/math`)

The `math` module in llts-zig provides comprehensive mathematical operations, ranging from basic arithmetic and trigonometric functions to advanced floating-point classifications and C-math library wrappers. Many of these functions map directly to highly optimized native VM built-ins.

## Constants

### Standard Constants
- **`$PI`**: The mathematical constant π (3.141592653589793).
- **`$E`**: Euler's number (2.718281828459045).

### C Math Classification & Error Constants
These constants align with standard C `math.h` definitions for floating-point classification.
- **`$FP_NAN`**: Represents Not-a-Number (NaN) (0).
- **`$FP_INFINITE`**: Represents positive or negative infinity (1).
- **`$FP_ZERO`**: Represents zero (2).
- **`$FP_SUBNORMAL`**: Represents a subnormal (denormalized) floating-point number (3).
- **`$FP_NORMAL`**: Represents a normal floating-point number (4).
- **`$MATH_ERRNO`**: Math error from errno (1).
- **`$MATH_ERREXCEPT`**: Math error from floating-point exception (2).
- **`$math_errhandling`**: Math error handling mechanism (3).

## Basic Arithmetic
Provides basic operations implemented directly.

- **`add(a, b)`**: Returns `a + b`.
- **`sub(a, b)`**: Returns `a - b`.
- **`mul(a, b)`**: Returns `a * b`.
- **`div(a, b)`**: Returns `a / b`.
- **`mod(a, b)`**: Returns `a % b`.

## Core Mathematical Functions
These functions map directly to native VM routines for performance.

- **`pow(a, b)`**: Returns `a` raised to the power of `b`.
- **`sqr(a)`**: Returns the square of `a` (equivalent to `pow(a, 2)`).
- **`abs(a)`**: Returns the absolute value of `a`.
- **`floor(a)`**: Returns the largest integer less than or equal to `a`.
- **`ceil(a)`**: Returns the smallest integer greater than or equal to `a`.
- **`round(a)`**: Returns the value of `a` rounded to the nearest integer.
- **`sqrt(a)`**: Returns the square root of `a`. Throws a DomainError if `a < 0`.
- **`min(...args)`**: Returns the minimum value among the arguments. Can accept an arbitrary number of arguments.
- **`max(...args)`**: Returns the maximum value among the arguments. Can accept an arbitrary number of arguments.
- **`random()`**: Returns a pseudo-random floating-point number in the range `[0.0, 1.0)`.

### Trigonometric Functions
- **`sin(a)`**: Returns the sine of `a` (in radians).
- **`cos(a)`**: Returns the cosine of `a` (in radians).
- **`tan(a)`**: Returns the tangent of `a` (in radians).
- **`asin(a)`**: Returns the arc sine of `a`.
- **`acos(a)`**: Returns the arc cosine of `a`.
- **`atan(a)`**: Returns the arc tangent of `a`.
- **`atan2(y, x)`**: Returns the arc tangent of `y/x`, using the signs of the two arguments to determine the quadrant.

### Exponential and Logarithmic Functions
- **`log(a)`**: Returns the natural logarithm of `a`.
- **`log10(a)`**: Returns the base-10 logarithm of `a`.
- **`log2(a)`**: Returns the base-2 logarithm of `a`.
- **`exp(a)`**: Returns `e` raised to the power of `a`.
- **`cbrt(a)`**: Returns the cube root of `a`.

### Utility Functions
- **`trunc(a)`**: Returns the integer part of `a`, removing any fractional digits.
- **`sign(a)`**: Returns `1` if `a > 0`, `-1` if `a < 0`, and `0` if `a == 0`.

## Advanced Math (C `math.h` Wrappers)
The following functions provide a direct wrapper around standard C library `<math.h>` functions.

- **`acosh(a0)`**: Inverse hyperbolic cosine.
- **`asinh(a0)`**: Inverse hyperbolic sine.
- **`atanh(a0)`**: Inverse hyperbolic tangent.
- **`copysign(a0, a1)`**: Returns a value with the magnitude of `a0` and the sign of `a1`.
- **`cosh(a0)`**: Hyperbolic cosine.
- **`erf(a0)`**: Error function.
- **`erfc(a0)`**: Complementary error function.
- **`exp2(a0)`**: Base-2 exponential function.
- **`expm1(a0)`**: Returns `e^x - 1`.
- **`fabs(a0)`**: Absolute value of a floating-point number.
- **`fdim(a0, a1)`**: Positive difference between `a0` and `a1`.
- **`fma(a0, a1, a2)`**: Fused multiply-add (`a0 * a1 + a2`).
- **`fmax(a0, a1)`**: Maximum of two floating-point values.
- **`fmin(a0, a1)`**: Minimum of two floating-point values.
- **`fmod(a0, a1)`**: Floating-point remainder of `a0 / a1`.
- **`frexp(a0)`**: Decomposes a floating-point number into a normalized fraction and an integral power of 2.
- **`hypot(a0, a1)`**: Computes the square root of the sum of the squares of `a0` and `a1`.
- **`ilogb(a0)`**: Extracts the exponent of `a0` as an integer.
- **`ldexp(a0, a1)`**: Multiplies `a0` by 2 raised to the power `a1`.
- **`lgamma(a0)`**: Log gamma function.
- **`llrint(a0)`**: Rounds `a0` to the nearest long long integer.
- **`llround(a0)`**: Rounds `a0` to the nearest long long integer, rounding halfway cases away from zero.
- **`log1p(a0)`**: Natural logarithm of `1 + a0`.
- **`logb(a0)`**: Extracts the exponent of `a0`.
- **`lrint(a0)`**: Rounds `a0` to the nearest long integer.
- **`lround(a0)`**: Rounds `a0` to the nearest long integer, rounding halfway cases away from zero.
- **`modf(a0)`**: Breaks `a0` into integral and fractional parts, returning the fractional part.
- **`nan(s)`**: Returns a NaN value.
- **`nearbyint(a0)`**: Rounds `a0` to an integer value in floating-point format.
- **`nextafter(a0, a1)`**: Next representable floating-point value after `a0` in the direction of `a1`.
- **`nexttoward(a0, a1)`**: Next representable floating-point value after `a0` in the direction of `a1`.
- **`remainder(a0, a1)`**: Computes the remainder of dividing `a0` by `a1`.
- **`remquo(a0, a1)`**: Computes remainder and a part of the quotient upon division of `a0` by `a1`.
- **`rint(a0)`**: Rounds `a0` to an integer value using current rounding direction.
- **`scalbln(a0, a1)`**: Multiplies `a0` by `FLT_RADIX` raised to the power of `a1` (long integer).
- **`scalbn(a0, a1)`**: Multiplies `a0` by `FLT_RADIX` raised to the power of `a1` (integer).
- **`sinh(a0)`**: Hyperbolic sine.
- **`tanh(a0)`**: Hyperbolic tangent.
- **`tgamma(a0)`**: Gamma function.

## Floating-Point Classification and Inspection
Provides methods for inspecting the type and properties of floating-point numbers.

- **`fpclassify(a0)`**: Returns a classification macro value (`$FP_NAN`, `$FP_INFINITE`, `$FP_ZERO`, `$FP_SUBNORMAL`, or `$FP_NORMAL`).
- **`isfinite(a0)`**: Returns `true` if `a0` is neither infinity nor NaN.
- **`isgreater(a0, a1)`**: Returns `true` if `a0` > `a1`.
- **`isgreaterequal(a0, a1)`**: Returns `true` if `a0` >= `a1`.
- **`isinf(a0)`**: Returns `true` if `a0` is positive or negative infinity.
- **`isless(a0, a1)`**: Returns `true` if `a0` < `a1`.
- **`islessequal(a0, a1)`**: Returns `true` if `a0` <= `a1`.
- **`islessgreater(a0, a1)`**: Returns `true` if `a0` < `a1` or `a0` > `a1` (equivalent to `a0 != a1` excluding NaN cases).
- **`isnan(a0)`**: Returns `true` if `a0` is NaN.
- **`isnormal(a0)`**: Returns `true` if `a0` is normal (neither zero, subnormal, infinite, nor NaN).
- **`isunordered(a0, a1)`**: Returns `true` if either `a0` or `a1` is NaN.
- **`signbit(a0)`**: Returns `true` if the sign of `a0` is negative.

## Special Values
- **`hugeVal()`**: Returns positive infinity.
- **`infinity()`**: Returns positive infinity.
- **`nanValue()`**: Returns a NaN (Not-a-Number) value.

## Examples

### Basic Arithmetic and Functions
```javascript
const math = @import("std/math");

const sum = math.add(10, 5); // 15
const p = math.pow(2, 3);    // 8
const s = math.sqrt(16);     // 4

const mn = math.min(10, 20, 5, 30); // 5
const mx = math.max(10, 20, 5, 30); // 30
```

### Trigonometry and Constants
```javascript
const math = @import("std/math");

const sine = math.sin(math.$PI / 2); // 1.0
const cosine = math.cos(math.$PI);   // -1.0
```

### Floating-Point Classification
```javascript
const math = @import("std/math");

const is_inf = math.isinf(math.infinity()); // true
const is_nan = math.isnan(math.nanValue()); // true

const classification = math.fpclassify(0.0); // equals math.$FP_ZERO
```
