const std = @import("std");

pub const prefix = "-VR0001-";

pub fn generate() [20]u8 {
    var value = (prefix ++ "000000000000").*;
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    var random_bytes: [12]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    for (random_bytes, 0..) |byte, index| {
        value[prefix.len + index] = alphabet[byte % alphabet.len];
    }

    return value;
}

test "generated peer id keeps the client prefix" {
    const value = generate();

    try std.testing.expectEqual(@as(usize, 20), value.len);
    try std.testing.expectEqualStrings(prefix, value[0..prefix.len]);
}
