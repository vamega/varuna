const std = @import("std");

/// A 768-bit unsigned integer stored as 12 u64 limbs in little-endian limb order.
/// Byte serialization is big-endian (network order) per BEP 6.
pub const U768 = struct {
    limbs: [12]u64,

    pub fn zero() U768 {
        return .{ .limbs = [_]u64{0} ** 12 };
    }

    /// Import from 96-byte big-endian buffer.
    pub fn fromBytes(bytes: [96]u8) U768 {
        var result: U768 = undefined;
        for (0..12) |i| {
            // Limb 0 = least significant = last 8 bytes of input
            const offset = (11 - i) * 8;
            result.limbs[i] = std.mem.readInt(u64, bytes[offset..][0..8], .big);
        }
        return result;
    }

    /// Export to 96-byte big-endian buffer.
    pub fn toBytes(self: U768) [96]u8 {
        var result: [96]u8 = undefined;
        for (0..12) |i| {
            const offset = (11 - i) * 8;
            std.mem.writeInt(u64, result[offset..][0..8], self.limbs[i], .big);
        }
        return result;
    }

    /// Create from a single u64 value.
    pub fn fromU64(v: u64) U768 {
        var result = zero();
        result.limbs[0] = v;
        return result;
    }

    /// Compare: returns <0, 0, >0
    pub fn cmp(a: U768, b: U768) i2 {
        var i: usize = 12;
        while (i > 0) {
            i -= 1;
            if (a.limbs[i] < b.limbs[i]) return -1;
            if (a.limbs[i] > b.limbs[i]) return 1;
        }
        return 0;
    }

    /// Addition with carry, returns (result, carry).
    pub fn addWithCarry(a: U768, b: U768) struct { result: U768, carry: u1 } {
        var result: U768 = undefined;
        var carry: u1 = 0;
        for (0..12) |i| {
            const sum1 = @addWithOverflow(a.limbs[i], b.limbs[i]);
            const sum2 = @addWithOverflow(sum1[0], @as(u64, carry));
            result.limbs[i] = sum2[0];
            carry = sum1[1] | sum2[1];
        }
        return .{ .result = result, .carry = carry };
    }

    /// Subtraction: a - b (assumes a >= b).
    pub fn sub(a: U768, b: U768) U768 {
        var result: U768 = undefined;
        var borrow: u1 = 0;
        for (0..12) |i| {
            const diff1 = @subWithOverflow(a.limbs[i], b.limbs[i]);
            const diff2 = @subWithOverflow(diff1[0], @as(u64, borrow));
            result.limbs[i] = diff2[0];
            borrow = diff1[1] | diff2[1];
        }
        return result;
    }

    /// Multiply two U768 values and reduce modulo P.
    /// Uses schoolbook multiplication with intermediate reduction.
    pub fn mulMod(a: U768, b: U768, p: U768) U768 {
        // Double-width product: 24 limbs
        var product = [_]u64{0} ** 24;

        for (0..12) |i| {
            var carry: u64 = 0;
            for (0..12) |j| {
                const wide = @as(u128, a.limbs[i]) * @as(u128, b.limbs[j]) +
                    @as(u128, product[i + j]) + @as(u128, carry);
                product[i + j] = @truncate(wide);
                carry = @truncate(wide >> 64);
            }
            product[i + 12] = carry;
        }

        // Reduce the 1536-bit product modulo P using Barrett-like division
        // We do repeated subtraction with shifted P for simplicity but
        // starting from the MSB for efficiency
        return reduceWide(&product, p);
    }

    /// Reduce a 24-limb product modulo P.
    /// Uses the "top-limb elimination" approach: for each high limb position from top
    /// down to 12, subtract work[top] * P << (shift*64) until work[top] == 0.
    /// The quotient estimate q = work[top] may be off by 1, so we retry until done.
    fn reduceWide(product: *const [24]u64, p: U768) U768 {
        // Copy to mutable working space
        var work = [_]u64{0} ** 25; // extra limb for borrow detection
        @memcpy(work[0..24], product);

        // Find the highest non-zero limb
        var top: usize = 23;
        while (top > 11 and work[top] == 0) {
            if (top == 0) break;
            top -= 1;
        }

        // For each limb position from top down to 12, reduce until work[top] == 0.
        // The estimate q = work[top] may underestimate by 1, so we loop per position.
        while (top >= 12) {
            // Reduce work[top] to 0 by subtracting multiples of p << (shift*64).
            // Since q = work[top] underestimates by at most 1, this loops at most twice.
            while (work[top] != 0) {
                const q = work[top];
                const shift = top - 12;
                var borrow: u64 = 0;
                for (0..12) |i| {
                    const wide = @as(u128, q) * @as(u128, p.limbs[i]) + @as(u128, borrow);
                    const lo: u64 = @truncate(wide);
                    borrow = @truncate(wide >> 64);
                    const diff = @subWithOverflow(work[shift + i], lo);
                    work[shift + i] = diff[0];
                    if (diff[1] != 0) borrow += 1;
                }
                // Propagate borrow upward from position shift+12 = top
                var k = shift + 12;
                while (k < 25 and borrow != 0) : (k += 1) {
                    const diff = @subWithOverflow(work[k], borrow);
                    work[k] = diff[0];
                    borrow = if (diff[1] != 0) 1 else 0;
                }
            }
            if (top == 0) break;
            top -= 1;
        }

        // Final: extract lower 12 limbs and do final reductions
        var result: U768 = undefined;
        @memcpy(&result.limbs, work[0..12]);

        // May need up to 2 final subtractions (in practice 0 or 1)
        while (cmp(result, p) >= 0) {
            result = sub(result, p);
        }
        return result;
    }

    /// Modular exponentiation: base^exp mod p.
    /// Uses square-and-multiply (left-to-right binary method).
    pub fn powMod(base: U768, exp: U768, p: U768) U768 {
        var result = fromU64(1);
        var b = base;

        // Process each bit from LSB to MSB
        for (0..12) |limb_idx| {
            var bits = exp.limbs[limb_idx];
            for (0..64) |_| {
                if (bits & 1 == 1) {
                    result = mulMod(result, b, p);
                }
                b = mulMod(b, b, p);
                bits >>= 1;
            }
        }
        return result;
    }

    /// Check if zero.
    pub fn isZero(self: U768) bool {
        for (self.limbs) |l| {
            if (l != 0) return false;
        }
        return true;
    }
};

test "U768 from/to bytes roundtrip" {
    const dh_prime_bytes = @import("mse.zig").dh_prime_bytes;
    const bytes = dh_prime_bytes;
    const val = U768.fromBytes(bytes);
    const back = val.toBytes();
    try std.testing.expectEqualSlices(u8, &bytes, &back);
}

test "U768 from u64" {
    const val = U768.fromU64(42);
    const bytes = val.toBytes();
    // Should be zero except the last byte
    for (0..94) |i| {
        try std.testing.expectEqual(@as(u8, 0), bytes[i]);
    }
    try std.testing.expectEqual(@as(u8, 0), bytes[94]);
    try std.testing.expectEqual(@as(u8, 42), bytes[95]);
}

test "U768 addition" {
    const a = U768.fromU64(0xFFFFFFFFFFFFFFFF);
    const b = U768.fromU64(1);
    const result = U768.addWithCarry(a, b);
    try std.testing.expectEqual(@as(u64, 0), result.result.limbs[0]);
    try std.testing.expectEqual(@as(u64, 1), result.result.limbs[1]);
    try std.testing.expectEqual(@as(u1, 0), result.carry);
}

test "U768 subtraction" {
    const a = U768.fromU64(100);
    const b = U768.fromU64(42);
    const result = U768.sub(a, b);
    try std.testing.expectEqual(@as(u64, 58), result.limbs[0]);
}

test "U768 comparison" {
    const a = U768.fromU64(100);
    const b = U768.fromU64(42);
    try std.testing.expect(U768.cmp(a, b) > 0);
    try std.testing.expect(U768.cmp(b, a) < 0);
    try std.testing.expect(U768.cmp(a, a) == 0);
}

test "U768 mulMod small values" {
    const dh_prime_bytes = @import("mse.zig").dh_prime_bytes;
    const p = U768.fromBytes(dh_prime_bytes);
    const a = U768.fromU64(7);
    const b = U768.fromU64(11);
    const result = U768.mulMod(a, b, p);
    try std.testing.expectEqual(@as(u64, 77), result.limbs[0]);
}

test "U768 powMod: 2^10 mod P" {
    const dh_prime_bytes = @import("mse.zig").dh_prime_bytes;
    const p = U768.fromBytes(dh_prime_bytes);
    const base = U768.fromU64(2);
    const exp = U768.fromU64(10);
    const result = U768.powMod(base, exp, p);
    try std.testing.expectEqual(@as(u64, 1024), result.limbs[0]);
}
