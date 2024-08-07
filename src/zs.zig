const std = @import("std");
const hashmap = @import("hash_map.zig");
const array_list = @import("array_list.zig");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

pub fn serializeIntoSlice(allocator: std.mem.Allocator, comptime T: type, value: T) ![]const u8 {
    var arr = std.ArrayList(u8).init(allocator);
    const writer = arr.writer();
    try serialize(writer, T, value);
    return arr.toOwnedSlice();
}

pub fn deserializeFromSlice(data: []const u8, comptime T: type, allocator: std.mem.Allocator) !T {
    var stream = std.io.fixedBufferStream(data);
    const reader = stream.reader();
    return deserialize(reader.any(), T, allocator);
}

pub fn serializedLength(comptime T: type, value: T) !u64 {
    var writer = std.io.countingWriter(std.io.null_writer);
    try serialize(writer.writer(), T, value);
    return writer.bytes_written;
}

pub fn serialize(writer: anytype, comptime T: type, value: T) !void {
    @setEvalBranchQuota(10000);
    if (comptime hashmap.isAnyHashMap(T)) {
        try hashmap.serializeHashMap(writer, T, value);
        return;
    }
    if (comptime array_list.isAnyArrayList(T)) {
        try array_list.serializeArrayList(writer, T, value);
        return;
    }
    switch (@typeInfo(T)) {
        .Void => {},
        .Int, .Float, .Bool => {
            var copy = value;
            const bytes = std.mem.asBytes(&copy);
            sliceToLittle(u8, bytes[0..]);
            _ = try writer.write(bytes);
        },
        .Array => |arr| {
            for (value) |val| {
                try serialize(writer, arr.child, val);
            }
        },
        .Vector => |vec| {
            for (0..vec.len) |i| {
                try serialize(writer, vec.child, value[i]);
            }
        },
        .Pointer => |ptr| {
            switch (ptr.size) {
                .Slice => {
                    try writer.writeInt(u64, @intCast(value.len), .little);
                    for (value) |val| {
                        try serialize(writer, ptr.child, val);
                    }
                },
                else => unreachable,
            }
        },
        .Struct => |s| {
            switch (s.layout) {
                .auto, .@"extern" => {
                    inline for (s.fields) |field| {
                        try serialize(writer, field.type, @field(value, field.name));
                    }
                },
                .@"packed" => {
                    try serialize(writer, s.backing_integer.?, @bitCast(value));
                },
            }
        },
        .Optional => |o| {
            if (value != null) {
                try serialize(writer, bool, true);
                try serialize(writer, o.child, value.?);
            } else {
                try serialize(writer, bool, false);
            }
        },
        .Enum => {
            const num = @intFromEnum(value);
            try serialize(writer, @TypeOf(num), num);
        },
        .ErrorSet => {
            const v = @intFromError(value);
            try serialize(writer, @TypeOf(v), v);
        },
        .ErrorUnion => |u| {
            if (value) |v| {
                try serialize(writer, u8, 0);
                try serialize(writer, u.payload, v);
            } else |err| {
                try serialize(writer, u8, 1);
                try serialize(writer, u.error_set, err);
            }
        },
        .Union => |u| {
            if (u.tag_type == null) unreachable;
            const tag = std.meta.activeTag(value);
            const name = @tagName(value);

            try serialize(writer, @TypeOf(tag), tag);
            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, name, field.name)) {
                    const f = @field(value, field.name);
                    try serialize(writer, field.type, f);
                }
            }
        },
        else => unreachable,
    }
}

pub fn deserialize(reader: std.io.AnyReader, comptime T: type, allocator: std.mem.Allocator) !T {
    @setEvalBranchQuota(10000);
    var out: T = undefined;
    if (comptime hashmap.isAnyHashMap(T)) {
        return hashmap.deserializeHashMap(reader, T, allocator);
    }
    if (comptime array_list.isAnyArrayList(T)) {
        return array_list.deserializeArrayList(reader, T, allocator);
    }
    switch (@typeInfo(T)) {
        .Void => {},
        .Int, .Float, .Bool => {
            var bytes: [@sizeOf(T)]u8 = undefined;
            if (try reader.read(&bytes) == 0) return error.eof;
            littleSliceToNative(u8, &bytes);
            out = std.mem.bytesToValue(T, bytes[0..]);
        },
        .Array => |arr| {
            for (out[0..]) |*o| {
                o.* = try deserialize(reader, arr.child, allocator);
            }
        },
        .Vector => |vec| {
            for (0..vec.len) |i| {
                out[i] = try deserialize(reader, vec.child, allocator);
            }
        },
        .Pointer => |ptr| {
            switch (ptr.size) {
                .Slice => {
                    const len = try reader.readInt(u64, .little);
                    const tmp = try allocator.alloc(ptr.child, len);
                    for (tmp) |*t| {
                        t.* = try deserialize(reader, ptr.child, allocator);
                    }
                    out = tmp;
                },
                else => unreachable,
            }
        },
        .Struct => |s| {
            switch (s.layout) {
                .auto, .@"extern" => {
                    inline for (s.fields) |field| {
                        switch (@typeInfo(field.type)) {
                            .ErrorSet => {
                                const ErrInt = getErrorBackingType(field.type);
                                const value = try deserialize(reader, ErrInt, allocator);
                                if (!hasError(field.type, value)) return error.invalid_error_value;
                                @field(out, field.name) = @as(field.type, @errorCast(@errorFromInt(value)));
                            },
                            .ErrorUnion => |err_union_info| {
                                const has_error = try deserialize(reader, bool, allocator);
                                if (has_error) {
                                    const ErrInt = getErrorBackingType(err_union_info.error_set);
                                    const value = try deserialize(reader, ErrInt, allocator);
                                    if (!hasError(err_union_info.error_set, value)) return error.invalid_error_value;
                                    @field(out, field.name) = @as(err_union_info.error_set, @errorCast(@errorFromInt(value)));
                                } else {
                                    @field(out, field.name) = try deserialize(reader, err_union_info.payload, allocator);
                                }
                            },
                            else => @field(out, field.name) = try deserialize(reader, field.type, allocator),
                        }
                    }
                },
                .@"packed" => {
                    out = @bitCast(try deserialize(reader, s.backing_integer.?, allocator));
                },
            }
        },
        .Optional => |o| {
            const has_value = try deserialize(reader, bool, allocator);
            if (has_value) {
                out = try deserialize(reader, o.child, allocator);
            } else {
                out = null;
            }
        },
        .Enum => |e| {
            out = try std.meta.intToEnum(T, try deserialize(reader, e.tag_type, allocator));
        },
        .ErrorSet, .ErrorUnion => @compileError("It's not possible to deserialize an error set or error union. Consider wrapping it in a struct."),
        .Union => |u| {
            if (u.tag_type == null) unreachable;
            const tag = try deserialize(reader, u.tag_type.?, allocator);
            const name = @tagName(tag);

            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, name, field.name)) {
                    const val = try deserialize(reader, field.type, allocator);
                    out = @unionInit(T, field.name, val);
                }
            }
        },
        else => unreachable,
    }
    return out;
}

inline fn getErrorBackingType(comptime E: type) type {
    const t: E = undefined;
    return @TypeOf(@intFromError(t));
}

fn hasError(comptime ErrorSet: type, value: getErrorBackingType(ErrorSet)) bool {
    // TODO: make it faster
    const info = @typeInfo(ErrorSet).ErrorSet;
    if (info) |errors| {
        inline for (errors) |err| {
            const err_value = @intFromError(@field(ErrorSet, err.name));
            if (err_value == value) return true;
        }
        return false;
    } else {
        return false;
    }
}

inline fn sliceToLittle(comptime T: type, slice: []T) void {
    switch (native_endian) {
        .little => return,
        .big => std.mem.reverse(T, slice),
    }
}

inline fn littleSliceToNative(comptime T: type, slice: []T) void {
    sliceToLittle(T, slice);
}

test "Serialize/Deserialise basic usage" {
    const U = union(enum) {
        a: f32,
        b: u32,
        c: f128,
    };

    const SP = packed struct(u8) {
        a: u2 = 1,
        b: u4 = 5,
        _: u2 = undefined,
    };

    const S = struct {
        a: u8 = 127,
        pos: @Vector(3, f32) = .{ 0.0, 1.0, 2.0 },
        u: U = .{ .c = 500 },
        c: void = void{},
        p: SP = .{},
    };

    const slice: []const ?S = &.{ .{ .p = .{ .a = 3, .b = 0 } }, null, .{ .a = 66, .u = .{ .c = 5.0 } } };
    const serialized = try serializeIntoSlice(std.testing.allocator, @TypeOf(slice), slice);
    defer std.testing.allocator.free(serialized);
    const deserialized = try deserializeFromSlice(serialized, @TypeOf(slice), std.testing.allocator);
    defer std.testing.allocator.free(deserialized);

    try std.testing.expectEqualSlices(?S, slice, deserialized);
}

test "Serialize errors" {
    const Err = error{
        a,
        b,
        c,
    };
    const T = Err!u8;
    const serialized_no_error = try serializeIntoSlice(std.testing.allocator, T, 5);
    defer std.testing.allocator.free(serialized_no_error);
    const serialized_error = try serializeIntoSlice(std.testing.allocator, T, Err.b);
    defer std.testing.allocator.free(serialized_error);

    const err_b_value = @intFromError(Err.b);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x05 }, serialized_no_error);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01} ++ std.mem.asBytes(&err_b_value), serialized_error);
}
test "Deserialize error union" {
    const Err = error{
        a,
        b,
        c,
    };
    const S = struct {
        a: u32 = 255,
        err: Err!u16 = 12,
    };
    const s0 = S{};
    const s1 = S{ .err = Err.b };

    const serialized_no_error = &[_]u8{ 0xff, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00 };
    const serialized_error = &[_]u8{ 0xff, 0x00, 0x00, 0x00, 0x01 } ++ std.mem.asBytes(&Err.b);

    const d0 = try deserializeFromSlice(serialized_no_error, S, std.testing.failing_allocator);
    const d1 = try deserializeFromSlice(serialized_error, S, std.testing.failing_allocator);

    try std.testing.expectEqual(s0, d0);
    try std.testing.expectEqual(s1, d1);
}

test "Deserialize malformed error union" {
    const Err = error{
        a,
        b,
        c,
    };
    const S = struct {
        a: u32 = 255,
        err: Err!u16 = 12,
    };
    const serialized = &[_]u8{ 0xff, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00 };
    const d = deserializeFromSlice(serialized, S, std.testing.failing_allocator);

    try std.testing.expectError(error.invalid_error_value, d);
}

test "Deserialize malformed enum" {
    const Enum = enum(u8) {
        a = 0,
        b = 1,
        c = 2,
    };
    const data = [_]u8{0x3};
    const e = deserializeFromSlice(data[0..], Enum, std.testing.allocator);
    try std.testing.expectError(std.meta.IntToEnumError.InvalidEnumTag, e);
}

test "serializedLength" {
    const S = struct {
        a: u64 = 555,
        b: []const i16 = &.{ 1, 2, 3 },
        c: bool = true,
    };
    try std.testing.expectEqual(@as(u64, 23), try serializedLength(S, .{}));
}

test "Serialize/Deserialise BoundedArray" {
    const U = union(enum) {
        a: f32,
        b: u32,
        c: f128,
    };

    const SP = packed struct(u8) {
        a: u2 = 1,
        b: u4 = 5,
        _: u2 = undefined,
    };

    const S = struct {
        a: u8 = 127,
        pos: @Vector(3, f32) = .{ 0.0, 1.0, 2.0 },
        u: U = .{ .c = 500 },
        c: void = void{},
        p: SP = .{},
    };

    var array = std.BoundedArray(?S, 16){};
    array.append(.{ .p = .{ .a = 3, .b = 0 } }) catch unreachable;
    array.append(null) catch unreachable;
    array.append(.{ .a = 66, .u = .{ .c = 5.0 } }) catch unreachable;

    const serialized = try serializeIntoSlice(std.testing.allocator, @TypeOf(array), array);
    defer std.testing.allocator.free(serialized);
    const deserialized = try deserializeFromSlice(serialized, @TypeOf(array), std.testing.allocator);

    try std.testing.expectEqual(array.len, deserialized.len);
    try std.testing.expectEqualSlices(?S, array.slice(), deserialized.slice());
}

test "Serialize/Deserialise StaticBitSet" {
    var set0 = std.StaticBitSet(16).initEmpty();
    var set1 = std.StaticBitSet(128).initEmpty();

    set0.set(5);
    set0.set(10);

    set1.set(56);
    set1.set(111);

    const s0 = try serializeIntoSlice(std.testing.allocator, @TypeOf(set0), set0);
    const s1 = try serializeIntoSlice(std.testing.allocator, @TypeOf(set1), set1);
    defer std.testing.allocator.free(s0);
    defer std.testing.allocator.free(s1);
    const d0 = try deserializeFromSlice(s0, @TypeOf(set0), std.testing.allocator);
    const d1 = try deserializeFromSlice(s1, @TypeOf(set1), std.testing.allocator);

    try std.testing.expectEqual(set0, d0);
    try std.testing.expectEqual(set1, d1);
}
