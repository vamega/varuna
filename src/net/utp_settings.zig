const std = @import("std");

pub const UtpSettings = struct {
    packet_pool_initial_bytes: u64 = 64 * 1024 * 1024,
    packet_pool_max_bytes: u64 = 256 * 1024 * 1024,
    target_delay_ms: u32 = 100,
    min_timeout_ms: u32 = 500,
    connect_timeout_ms: u32 = 3000,
    syn_resends: u8 = 2,
    fin_resends: u8 = 2,
    data_resends: u8 = 3,

    pub fn targetDelayUs(self: UtpSettings) u32 {
        return msToUs(self.target_delay_ms);
    }

    pub fn minTimeoutUs(self: UtpSettings) u32 {
        return msToUs(self.min_timeout_ms);
    }

    pub fn connectTimeoutUs(self: UtpSettings) u32 {
        return msToUs(self.connect_timeout_ms);
    }

    fn msToUs(value: u32) u32 {
        return std.math.mul(u32, value, 1000) catch std.math.maxInt(u32);
    }
};
