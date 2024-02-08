const std = @import("std");
const zs = @import("zs.zig");

pub fn serializeHashMap(writer: anytype, comptime T: type, value: T) !void {
    if (comptime isHashMapUnmanaged(T) or isHashMap(T)) {
        if (isHashMap(T)) try zs.serialize(writer, @TypeOf(value.ctx), value.ctx);
        var it = value.iterator();
        try zs.serialize(writer, u64, value.count());
        while (it.next()) |entry| {
            try zs.serialize(writer, @TypeOf(entry.key_ptr.*), entry.key_ptr.*);
            try zs.serialize(writer, @TypeOf(entry.value_ptr.*), entry.value_ptr.*);
        }
        try zs.serialize(writer, bool, false);
    } else if (comptime isArrayHashMapUnmanaged(T) or isArrayHashMap(T)) {
        if (isArrayHashMap(T)) try zs.serialize(writer, @TypeOf(value.ctx), value.ctx);
        try zs.serialize(writer, u64, value.count());
        for (value.keys(), value.values()) |k, v| {
            try zs.serialize(writer, @TypeOf(k), k);
            try zs.serialize(writer, @TypeOf(v), v);
        }
        try zs.serialize(writer, bool, false);
    }
}

pub fn deserializeHashMap(reader: std.io.AnyReader, comptime T: type, allocator: std.mem.Allocator) !T {
    var out: T = undefined;
    const K = std.meta.fields(T.KV)[0].type;
    const V = std.meta.fields(T.KV)[1].type;

    if (comptime isHashMap(T) or isArrayHashMap(T)) {
        const ctx = try zs.deserialize(reader, @TypeOf(out.ctx), allocator);
        out = T.initContext(allocator, ctx);
    } else {
        out = T{};
    }

    const count = try zs.deserialize(reader, u64, allocator);
    for (0..count) |_| {
        const k = try zs.deserialize(reader, K, allocator);
        const v = try zs.deserialize(reader, V, allocator);
        if (comptime isHashMapUnmanaged(T)) try out.put(allocator, k, v) else try out.put(k, v);
    }

    return out;
}

pub fn isAnyHashMap(comptime T: type) bool {
    return isHashMapUnmanaged(T) or isArrayHashMapUnmanaged(T) or isArrayHashMap(T) or isHashMap(T);
}

fn isHashMapUnmanaged(comptime T: type) bool {
    if (@typeInfo(T) != .Struct) return false;
    return @hasField(T, "metadata") and @hasField(T, "size") and
        @hasField(T, "available") and
        @hasDecl(T, "Entry") and
        @hasDecl(T, "KV");
}

fn isArrayHashMapUnmanaged(comptime T: type) bool {
    if (@typeInfo(T) != .Struct) return false;
    return @hasField(T, "entries") and @hasField(T, "index_header") and
        @hasDecl(T, "Entry") and
        @hasDecl(T, "KV");
}

fn isArrayHashMap(comptime T: type) bool {
    if (@typeInfo(T) != .Struct) return false;
    return @hasField(T, "unmanaged") and @hasField(T, "allocator") and
        isArrayHashMapUnmanaged(std.meta.fields(T)[0].type) and
        @hasField(T, "ctx") and
        @hasDecl(T, "Entry") and
        @hasDecl(T, "KV");
}

fn isHashMap(comptime T: type) bool {
    if (@typeInfo(T) != .Struct) return false;
    return @hasField(T, "unmanaged") and @hasField(T, "allocator") and
        isHashMapUnmanaged(std.meta.fields(T)[0].type) and
        @hasField(T, "ctx") and
        @hasDecl(T, "Entry") and
        @hasDecl(T, "KV");
}

test "Serialize / Deserialize hashmap" {
    const S0 = struct {
        a: i64,
        b: i32,
    };
    const S1 = struct {
        a: i256,
    };

    var map = std.AutoHashMap(S0, S1).init(std.testing.allocator);
    defer map.deinit();
    try map.put(.{ .a = 1, .b = -1 }, .{ .a = 1 });
    try map.put(.{ .a = 15, .b = -2 }, .{ .a = 51 });
    try map.put(.{ .a = 3, .b = -3 }, .{ .a = -1 });
    try map.put(.{ .a = 7, .b = -4 }, .{ .a = 13 });

    const serialized = try zs.serializeSlice(std.testing.allocator, @TypeOf(map), map);
    defer std.testing.allocator.free(serialized);
    var deserialized = try zs.deserializeSlice(serialized, @TypeOf(map), std.testing.allocator);
    defer deserialized.deinit();

    try std.testing.expectEqual(map.count(), deserialized.count());
    var it0 = map.iterator();
    var it1 = deserialized.iterator();
    while (it0.next()) |e0| {
        const e1 = it1.next();
        try std.testing.expectEqual(e0.key_ptr.*, e1.?.key_ptr.*);
        try std.testing.expectEqual(e0.value_ptr.*, e1.?.value_ptr.*);
    }
}

test "isHashMapUnmanaged" {
    const A = std.AutoHashMapUnmanaged(u64, u64);
    const B = std.AutoHashMap(u64, u64);
    const C = std.AutoArrayHashMap(u64, u64);

    try std.testing.expect(isHashMapUnmanaged(A));
    try std.testing.expect(!isHashMapUnmanaged(B));
    try std.testing.expect(!isHashMapUnmanaged(C));
}

test "isHashMap" {
    const A = std.AutoHashMapUnmanaged(u64, u64);
    const B = std.AutoHashMap(u64, u64);
    const C = std.AutoArrayHashMap(u64, u64);

    try std.testing.expect(!isHashMap(A));
    try std.testing.expect(isHashMap(B));
    try std.testing.expect(!isHashMap(C));
}

test "isArrayHashMap" {
    const A = std.AutoHashMapUnmanaged(u64, u64);
    const B = std.AutoHashMap(u64, u64);
    const C = std.AutoArrayHashMap(u64, u64);

    try std.testing.expect(!isArrayHashMap(A));
    try std.testing.expect(!isArrayHashMap(B));
    try std.testing.expect(isArrayHashMap(C));
}
