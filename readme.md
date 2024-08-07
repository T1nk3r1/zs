# Zig Serializer (ZS)
ZS is a simple binary serializer written in Zig that supports many std containers.

# Installation
Use the following command to add ZS to your project:
`zig fetch --save https://github.com/T1nk3r1/zs/archive/<COMMIT_HASH>.tar.gz`

Then modify your `build.zig` file:
```zig
pub fn build() {
    // ...your code...
    const zs = b.dependency("zs", .{});

    // ...your code...

    exe.root_module.addImport("zs", zs.module("zs"));
}
```

# Supported types
ZS supports a variety of Zig types:
- `Void`
- `Int`
- `Float`
- `Bool`
- `Array`
- `Vector`
- `Slice`
- `Optional`
- `Enum`
- `ErrorSet`
- `ErrorUnion`
- `Struct`
- `Union`

It also supports some std containers:
- [ArrayList](https://github.com/T1nk3r1/zs/blob/master/src/array_list.zig)
- [HashMap/ArrayHashMap](https://github.com/T1nk3r1/zs/blob/master/src/hash_map.zig)
- BoundedArray
- StaticBitSet

# Example
```zig
const std = @import("std");
const zs = @import("zs");

pub fn main() !void {
    const Client = struct {
        id: u64,
        balance: f64,
        name: []const u8,
    };

    const my_client = Client{ .id = 100, .balance = 500.0, .name = "John" };
    const serialized = try zs.serializeIntoSlice(std.heap.c_allocator, Client, my_client);
    defer std.heap.c_allocator.free(serialized);

    // Some code...

    const des_client = try zs.deserializeFromSlice(serialized, Client, std.heap.c_allocator);
    defer std.heap.c_allocator.free(des_client.name);

    std.log.debug("id: {} balance: {d} name: {s}", .{ des_client.id, des_client.balance, des_client.name });
}
```

Output:
```
debug: id: 100 balance: 500 name: John
```
