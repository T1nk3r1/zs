const std = @import("std");
const zs = @import("zs.zig");

pub fn serializeArrayList(writer: anytype, comptime T: type, value: T) !void {
    try writer.writeInt(u64, @intCast(value.items.len), .little);
    for (value.items) |item| {
        try zs.serialize(writer, @TypeOf(item), item);
    }
}

pub fn deserializeArrayList(reader: std.io.AnyReader, comptime T: type, allocator: std.mem.Allocator) !T {
    var out: T = undefined;
    const alignment = @typeInfo(@TypeOf(out.items)).pointer.alignment;
    const Child = @typeInfo(@TypeOf(out.items)).pointer.child;
    const size: u64 = try reader.readInt(u64, .little);

    const items = try allocator.alignedAlloc(Child, alignment, size);
    for (0..size) |i| {
        items[i] = try zs.deserialize(reader, Child, allocator);
    }
    out.items = items;
    out.capacity = items.len;
    if (isArrayList(T)) out.allocator = allocator;

    return out;
}

pub fn isAnyArrayList(comptime T: type) bool {
    return isArrayListUnmanaged(T) or isArrayList(T);
}

fn isArrayListUnmanaged(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return std.mem.containsAtLeast(u8, @typeName(T), 1, "array_list.ArrayListAlignedUnmanaged(");
}

fn isArrayList(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return std.mem.containsAtLeast(u8, @typeName(T), 1, "array_list.ArrayListAligned(");
}

test "Serialize / Deserialize ArrayList" {
    const S0 = struct {
        a: i64,
        b: i32,
    };

    var list = std.ArrayList(S0).init(std.testing.allocator);
    defer list.deinit();
    try list.append(.{ .a = 1, .b = -1 });
    try list.append(.{ .a = 15, .b = -2 });
    try list.append(.{ .a = 3, .b = -3 });
    try list.append(.{ .a = 7, .b = -4 });

    const serialized = try zs.serializeIntoSlice(std.testing.allocator, @TypeOf(list), list);
    defer std.testing.allocator.free(serialized);
    var deserialized = try zs.deserializeFromSlice(serialized, @TypeOf(list), std.testing.allocator);
    defer deserialized.deinit();

    try std.testing.expectEqual(list.items.len, deserialized.items.len);
    try std.testing.expectEqual(std.testing.allocator, deserialized.allocator);
    try std.testing.expectEqualSlices(S0, list.items, deserialized.items);
}

test "isArrayListUnmanaged" {
    const A = std.ArrayList(u64);
    const B = std.ArrayListUnmanaged(u64);

    try std.testing.expect(!isArrayListUnmanaged(A));
    try std.testing.expect(isArrayListUnmanaged(B));
}

test "isArrayList" {
    const A = std.ArrayList(u64);
    const B = std.ArrayListUnmanaged(u64);

    try std.testing.expect(isArrayList(A));
    try std.testing.expect(!isArrayList(B));
}
