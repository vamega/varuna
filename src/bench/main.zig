const std = @import("std");
const varuna = @import("varuna");

pub fn main() !void {
    var timer = try std.time.Timer.start();
    const iterations: usize = 100_000;

    var checksum: u64 = 0;
    for (0..iterations) |_| {
        const parsed = try varuna.runtime.kernel.parseRelease("6.6.87.2-microsoft-standard-WSL2");
        checksum +%= parsed.patch;
    }

    const elapsed_ns = timer.read();
    const per_iteration_ns = @divTrunc(elapsed_ns, iterations);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        "kernel parser benchmark: iterations={}, total_ns={}, ns_per_iteration={}, checksum={}\n",
        .{ iterations, elapsed_ns, per_iteration_ns, checksum },
    );
    try stdout.flush();
}
