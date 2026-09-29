// expect: AtomicHistogram: bounds debe ser estrictamente creciente
const zkit = @import("zkit");
test {
    var h: zkit.AtomicHistogram(&.{ 0, 10, 10 }) = .{};
    h.record(1);
}
