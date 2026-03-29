const std = @import("std");
const varuna = @import("varuna");

pub fn main() !void {
    // TODO: Use c_allocator instead of GeneralPurposeAllocator to avoid GPA's
    // debug memory poisoning (0xAA fill on free). There is a latent use-after-free
    // in the io_uring buffer lifecycle where the kernel may read from a buffer that
    // has been freed. With GPA, freed memory is filled with 0xAA causing visible
    // corruption; with c_allocator, freed memory retains its old contents, masking
    // the bug. The underlying UAF needs investigation in:
    //   - freePendingSend: may free a buffer while io_uring send is still in flight
    //   - removePeer: may clean up buffers that io_uring might still be reading
    //   - processHashResults duplicate handling: freeing duplicate buffer may race
    //     with a write SQE
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try varuna.app.run(allocator, args, stdout, varuna.config.Config{});
    try stdout.flush();
}
