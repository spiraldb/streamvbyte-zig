# Zig StreamVByte

A pure Zig implementation of [StreamVByte](https://github.com/lemire/streamvbyte) encoding.

Inline ASM is used for a runtime shuffle (tbl.16b, pshufb) operation, falling back to a (very slow) scalar
implementation for non SSE3 or NEON architectures.

> This library should be treated as a toy! It has not been thoroughly tested, nor is it used in production.

The source code is released under the [MIT license](https://opensource.org/licenses/MIT).