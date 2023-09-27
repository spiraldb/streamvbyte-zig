const std = @import("std");
const Allocator = std.mem.Allocator;
const tblz = @import("./tblz.zig");
const builtin = @import("builtin");

const ValueVec = @Vector(4, u32);
const ShuffleVec = @Vector(16, i8);
const CodeVec = @Vector(4, u2);
const PADDING = 16;

const encode_shuffles: [256]ShuffleVec = blk: {
    var shuffles: [256]ShuffleVec = undefined;
    for (0..256) |code_idx| {
        shuffles[code_idx] = encode_shuffle_mask(code_idx);
    }
    break :blk shuffles;
};

const decode_shuffles: [256]ShuffleVec = blk: {
    var shuffles: [256]ShuffleVec = undefined;
    inline for (0..255) |c| {
        shuffles[c] = decode_shuffle_mask(c);
    }
    break :blk shuffles;
};

const lengths: [256]u8 = blk: {
    var lengths_: [256]u8 = undefined;
    for (0..256) |code_idx| {
        const code = @as(CodeVec, @bitCast(@as(u8, @truncate(code_idx))));
        lengths_[code_idx] = @reduce(.Add, @as(@Vector(4, u8), code)) + 4;
    }
    break :blk lengths_;
};

fn encode_shuffle_mask(comptime code_idx: u8) ShuffleVec {
    @setEvalBranchQuota(8 * 16 * 256);

    const code = @as(CodeVec, @bitCast(code_idx));
    var shuffle: [16]i8 = .{-1} ** 16;

    var shuffle_idx = 0;
    for (0..4) |int| {
        // For each integer, find out how many bytes we want from it.
        const byteLen = @as(u8, @intCast(code[int])) + 1;
        for (0..4) |b| {
            if (b < byteLen) {
                shuffle[shuffle_idx] = int * 4 + b;
                shuffle_idx += 1;
            }
        }
    }

    return shuffle;
}

fn decode_shuffle_mask(comptime code_idx: u8) ShuffleVec {
    @setEvalBranchQuota(8 * 16 * 256);

    const code = @as(CodeVec, @bitCast(code_idx));

    var mask: [16]i8 = .{-1} ** 16;
    var pos: u8 = 0;
    inline for (@as([4]u2, code), 0..) |code_u2, int| {
        const c: u8 = @intCast(code_u2);
        const offset = int * 4;
        inline for (0..c + 1) |byte| {
            const byte_u8: u8 = @intCast(byte);
            mask[offset + byte_u8] = pos + byte_u8;
        }
        pos += c + 1;
    }

    return mask;
}

pub fn maxCompressedSize(length: usize) usize {
    return controlBytesSize(length) + maxCompressedDataSize(length);
}

pub fn maxCompressedDataSize(length: usize) usize {
    return length * @sizeOf(u32) + PADDING;
}

pub fn controlBytesSize(length: usize) usize {
    return (length + 3) / 4;
}

/// Encode the elements returning the number of bytes written to the output array.
pub fn encode(elems: []const u32, out: []u8) usize {
    var control = out[0..controlBytesSize(elems.len)];
    var data = out[control.len..];

    var count: usize = 0;
    var idx: usize = 0;
    var written: usize = 0;
    for (0..elems.len / 4) |_| {
        written += encode_quad(elems[count..][0..4], control[idx..], data[written..]);
        count += 4;
        idx += 1;
    }

    if (count < elems.len) {
        written += encode_scalar(elems[count..], control[elems.len / 4 ..], data[written..]);
    }

    // Ensure the padding exists
    @memset(data[written..][0..PADDING], 0);
    written += PADDING;

    return control.len + written;
}

inline fn encode_quad(elems: *const [4]u32, control: []u8, data: []u8) usize {
    const elemsVec = @as(ValueVec, elems.*);

    // Immediately casting to an i32 "encourages" LLVM to use a CLZ instruction
    const leadingZeros = @as(@Vector(4, i32), @clz(elemsVec));

    // Shift by 3 to divide by 8 and get a leading byte count
    const leadingZerosBytes = leadingZeros >> @splat(3);
    // Saturated subtract from 3 (saturated => meaning overflow sticks to zero).
    // TODO(ngates): Zig does have a builtin, but it may be faster by hand?
    const codeBytesOverflow = @as(@Vector(4, i32), @splat(3)) - leadingZerosBytes;
    const codeBytes = @select(
        i32,
        codeBytesOverflow < @as(@Vector(4, i32), @splat(0)),
        @as(@Vector(4, i32), @splat(0)),
        codeBytesOverflow,
    );

    // We now have a 2-bit code for each integer. Just need to get them in the right place.
    // Left-shift the bits in each the relative positions, then reduce.
    const shifted = @as(@Vector(4, u32), @bitCast(codeBytes)) << @Vector(4, u8){ 0, 2, 4, 6 };
    const code = @as(u8, @truncate(@reduce(.Or, shifted)));
    control[0] = code;

    // Grab the input bytes we need by computing (looking up) our shuffle mask.
    const outputLength = lengths[code];

    const input = @as(@Vector(16, u8), @bitCast(elems.*));
    data[0..16].* = tblz.tableLookupBytesOr0(input, encode_shuffles[code]);

    return outputLength;
}

fn encode_scalar(elems: []const u32, control: []u8, data: []u8) usize {
    if (elems.len == 0) {
        return 0;
    }

    // We build up the control data into a var u8 to avoid too many loads/stores.
    var controlBuffer = control;
    var shift: u8 = 0; // cycles 0, 2, 4, 6, 0, 2, 4, 6, ...
    var key: u8 = 0;
    var written: usize = 0;
    for (elems) |e| {
        const code = encode_data(e, data[written..]);
        written += code + 1;
        key = key | (code << @truncate(shift));
        shift += 2;
    }

    controlBuffer[0] = key;
    return written;
}

fn encode_data(elem: u32, data: []u8) u8 {
    const elemBytes = @as([4]u8, @bitCast(elem));
    if (elem < (1 << 8)) { // 1 byte
        data[0] = elemBytes[0];
        return 0;
    } else if (elem < (1 << 16)) { // 2 bytes
        @memcpy(data[0..2], elemBytes[0..2]);
        return 1;
    } else if (elem < (1 << 24)) { // 3 bytes
        @memcpy(data[0..3], elemBytes[0..3]);
        return 2;
    } else { // 4 bytes
        @memcpy(data[0..4], elemBytes[0..4]);
        return 3;
    }
}

pub fn decode(encoded: []const u8, elems: []u32) void {
    const control = encoded[0..controlBytesSize(elems.len)];
    const data = encoded[control.len..];

    var count: usize = 0;
    var idx: usize = 0;
    var consumed: usize = 0;
    while (count + 3 < elems.len) {
        // The buffer padding is required for this data[0..16] slice
        consumed += decode_quad(control[idx], data[consumed..][0..16].*, elems[count..][0..4]);
        count += 4;
        idx += 1;
    }

    // Decode the remainder
    const remainder = elems.len - count;
    if (remainder > 0) {
        var ctrl_byte = control[idx];
        for (0..remainder) |r| {
            const shift = 6 - (r * 2);
            const control_bits: u8 = (ctrl_byte >> @intCast(shift)) & 0x03;
            consumed += decode_data(control_bits, data[consumed..], &elems[count]);
            count += 1;
        }
    }
}

fn decode_quad(control: u8, data: [16]u8, elems: []u32) usize {
    const decoded = tblz.tableLookupBytesOr0(@bitCast(data), decode_shuffles[control]);
    std.mem.sliceAsBytes(elems[0..4])[0..16].* = decoded;
    return lengths[control];
}

fn decode_data(control: u8, data: []const u8, elem: *u32) u8 {
    elem.* = 0;
    var elemBytes: *[4]u8 = @ptrCast(elem);

    if (control == 0) { // 1 bytes
        elemBytes[0] = data[0];
        return 1;
    } else if (control == 1) {
        @memcpy(elemBytes[0..2], data[0..2]);
        return 2;
    } else if (control == 2) {
        @memcpy(elemBytes[0..3], data[0..3]);
        return 3;
    } else {
        @memcpy(elemBytes, data[0..4]);
        return 4;
    }
}

test "encode zero elems" {
    var data = [_]u8{0} ** 16;
    const compressed_size = encode(&.{}, &data);

    try std.testing.expectEqual(@as(usize, PADDING), compressed_size);
}

test "encode non-quad elems" {
    const ally = std.testing.allocator;

    const out = try ally.alloc(u8, maxCompressedSize(3));
    defer ally.free(out);

    const compressed_size = encode(&.{ 1, 2, 3 }, out);

    const decoded = try ally.alloc(u32, 3);
    defer ally.free(decoded);
    decode(out[0..compressed_size], decoded);

    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, decoded);
}

test "zig streamvbyte" {
    try bench("Zig StreamVByte", @This());
}

test "original streamvbyte" {
    const c_svb = @cImport({
        @cInclude("streamvbyte.h");
    });

    const SVB = struct {
        pub fn encode(values: []const u32, out: []u8) usize {
            return c_svb.streamvbyte_encode(values.ptr, @intCast(values.len), out.ptr);
        }

        pub fn decode(data: []const u8, values: []u32) void {
            _ = c_svb.streamvbyte_decode(data.ptr, values.ptr, @intCast(values.len));
        }
    };

    try bench("Original C StreamVByte", SVB);
}

fn bench(comptime name: []const u8, comptime Impl: anytype) !void {
    const testing = std.testing;
    const ally = std.testing.allocator;

    const n = 1_000_000;
    const max_int = 10_000;
    const loops = 20;

    std.debug.print("{s}\n", .{name});

    // Use a constant seed for now
    var R = std.rand.DefaultPrng.init(0);
    const rand = R.random();
    var values = try ally.alloc(u32, n);
    defer ally.free(values);
    for (0..values.len) |i| {
        values[i] = rand.intRangeAtMostBiased(u32, 0, max_int);
    }

    const out = try ally.alloc(u8, maxCompressedSize(n));
    defer ally.free(out);

    var timer = try std.time.Timer.start();

    var total_ns: usize = 0;
    var compressed_size: usize = undefined;
    for (0..loops) |_| {
        timer.reset();
        compressed_size = Impl.encode(values, out);
        total_ns += timer.read();
        std.mem.doNotOptimizeAway(compressed_size);
    }
    var mean_ns = total_ns / loops;
    std.debug.print("\tEncode {} ints between {} and {} in mean {}ns\n", .{ n, 0, max_int, mean_ns });
    std.debug.print("\t=> {} million ints per second\n\n", .{1_000 * n / mean_ns});

    const decoded = try ally.alloc(u32, values.len);
    defer ally.free(decoded);

    total_ns = 0;
    for (0..loops) |_| {
        timer.reset();
        Impl.decode(out[0..compressed_size], decoded);
        total_ns += timer.read();
        std.mem.doNotOptimizeAway(decoded);
    }
    mean_ns = total_ns / loops;
    std.debug.print("\tDecode {} ints between {} and {} in mean {}ns\n", .{ n, 0, max_int, mean_ns });
    std.debug.print("\t=> {} million ints per second\n\n", .{1_000 * n / mean_ns});

    try testing.expectEqualSlices(u32, values, decoded);
}
