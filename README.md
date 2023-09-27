# Zig StreamVByte

A Zig port of [Stream VByte](https://github.com/lemire/streamvbyte).

This project started as an experiment to explore the feasibility and
DevX of implementing compression codecs in Zig.

In particular,
* Leveraging comptime to avoid writing (or generating) repetitive code.
* Using the Zig @Vector API for portable SIMD.

### Comptime Lookup Tables

Stream VByte leverages lookup tables (LUTs) for pre-computing shuffle
masks as well as the lengths of compressed quads.

Zig's comptime feature allows us to generate static LUTs at compile-time
by defining them in regular Zig. This makes it possible for the reader
to understand the origin of what are otherwise typically opaque "magic"
values.

### Zig SIMD

Zig leans on LLVM for its `@Vector` SIMD API. While Zig offers a `@shuffle`
builtin to operate on vectors, LLVM (and therefore Zig) require the shuffle
mask to be comptime known.

Since the shuffle mask is a lookup based on runtime control bits, it isn't
possible to use the `@shuffle` builtin.

> It is worth noting at this point that we use Zig 0.11.0.

We _were_ able to generate functions for each of the shuffle masks, and then
store these function pointers in a LUT. But since these functions cannot be inlined, the overhead was far too much.

We also tried to `@cImport` the relevant instrinsics headers. But found that
Zig is currently unable to inline `callconv(.C)` extern functions.

This left us to implement a shuffle function ourselves using `pshufb`
(and `tbl.16b`) with Zig's inline ASM. Whilst this isn't ideal, it doesn't
seem unreasonable for these instructions to be supported by the builtin
`@shuffle` operator when the operand is only runtime known.

## Benchmarks

We spent most of our time playing around with shuffle LUTs, so
the remainder of the code isn't particularly heavily optimized.
Nor have we run these benchmarks on a variety of architectures.
Take everything with a handful of salt. Especially given how
much variance there is in the "benchmarks".

```bash "M2 Macbook Air"
$ zig build test -Doptimize=ReleaseFast
Zig StreamVByte
	Encode 10000000 ints between 0 and 10000 in mean 3467410ns
	=> 2883 million ints per second

	Decode 10000000 ints between 0 and 10000 in mean 1681129ns
	=> 5948 million ints per second

Original C StreamVByte
	Encode 10000000 ints between 0 and 10000 in mean 2065012ns
	=> 4842 million ints per second

	Decode 10000000 ints between 0 and 10000 in mean 1669633ns
	=> 5989 million ints per second
```

---

The source code is released under the [MIT license](https://opensource.org/licenses/MIT).
