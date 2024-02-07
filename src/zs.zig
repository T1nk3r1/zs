const std = @import("std");
const hashmap = @import("hash_map.zig");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

pub fn serializeSlice(allocator: std.mem.Allocator, comptime T: type, value: T) ![]const u8 {
    var arr = std.ArrayList(u8).init(allocator);
    const writer = arr.writer();
    try serialize(writer, T, value);
    return arr.toOwnedSlice();
}

pub fn deserializeSlice(data: []const u8, comptime T: type, allocator: std.mem.Allocator) !T {
    var stream = std.io.fixedBufferStream(data);
    const reader = stream.reader();
    return deserialize(reader.any(), T, allocator);
}

pub fn serialize(writer: anytype, comptime T: type, value: T) !void {
    if (comptime hashmap.isAnyHashMap(T)) {
        try hashmap.serializeHashMap(writer, T, value);
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
                .Auto, .Extern => {
                    inline for (s.fields) |field| {
                        try serialize(writer, field.type, @field(value, field.name));
                    }
                },
                .Packed => {
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
    var out: T = undefined;
    if (comptime hashmap.isAnyHashMap(T)) {
        return hashmap.deserializeHashMap(reader, T, allocator);
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
            for (out) |*o| {
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
                .Auto, .Extern => {
                    inline for (s.fields) |field| {
                        @field(out, field.name) = try deserialize(reader, field.type, allocator);
                    }
                },
                .Packed => {
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
            out = @enumFromInt(try deserialize(reader, e.tag_type, allocator));
        },
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
    const serialized = try serializeSlice(std.testing.allocator, @TypeOf(slice), slice);
    defer std.testing.allocator.free(serialized);
    const deserialized = try deserializeSlice(serialized, @TypeOf(slice), std.testing.allocator);
    defer std.testing.allocator.free(deserialized);

    try std.testing.expectEqualSlices(?S, slice, deserialized);
}
