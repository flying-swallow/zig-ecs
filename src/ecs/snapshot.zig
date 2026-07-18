//! Registry serialization: dump a registry to an archive and restore it, either
//! into a fresh registry with identical entity ids (`SnapshotLoader`) or merged
//! into a live one with remote ids remapped to local ids (`ContinuousLoader`,
//! the client-applies-server-updates primitive).
//!
//! An archive is any type providing exactly:
//!
//!     pub fn write(self: *Archive, value: anytype) void
//!     pub fn read(self: *Archive, comptime T: type) T
//!
//! Values passed through are unsigned integers (counts, header fields), `Entity`,
//! and component values. Components must be plain data — no pointers or slices.
//! `BasicBufferArchive` below is the reference implementation.
//!
//! Wire format, as driven by `all()` (manual `entities()`/`component()` calls
//! write the same blocks with no header and no ordinal tags; all counts u64):
//!
//!     header:    u32 magic "ZECS" | u16 version | u16 reserved (0) | u64 schema hash
//!     entities:  u64 append_cursor | u64 free-chain head (Entity.null_index if none)
//!                | Entity * append_cursor (raw slots: live iff slot.index == position)
//!     component: u16 ordinal (tuple position) | u64 count
//!                | count * (Entity [+ value unless @sizeOf(T) == 0])
//!
//! The entities block is a full-fidelity pool dump: dead-slot versions and the
//! free-chain order survive, so `create()` after a load returns bit-identical
//! handles on both ends — required for deterministic netcode id allocation.
//!
//! The schema hash folds the entity bit-widths and every component's identity
//! (its `pub const serde_id: u32` if declared, else its fully-qualified type
//! name) plus its size, so renamed/reordered/resized components are rejected
//! loudly at load instead of silently corrupting. Declare `serde_id` on a
//! component to keep its hash stable across renames/moves.
//!
//! Loading replays through `Registry.add`, so construction signals fire for
//! every restored component (listeners see fully-inserted values), and loading
//! into a registry with owning groups keeps group membership correct (the
//! groups may reorder pool dense arrays while loading; order is not part of
//! the contract). Archives are trusted input: malformed bytes are safety-checked
//! UB in Debug builds, not errors — validate untrusted streams in your archive.

const std = @import("std");
const utils = @import("utils.zig");
const registry_mod = @import("registry.zig");
const Registry = registry_mod.Registry;
const Storage = registry_mod.Storage;
pub const Entity = registry_mod.Entity;

pub const snapshot_magic: u32 = 0x5343455A; // "ZECS"
pub const snapshot_version: u16 = 1;

pub const SchemaError = error{
    /// stream does not start with the snapshot magic
    InvalidMagic,
    /// stream was written by a newer format version
    UnsupportedVersion,
    /// reserved header bits are set
    ReservedFlagsSet,
    /// the component tuple (or entity type) differs from the writer's
    SchemaMismatch,
    /// a component block appeared out of tuple order — stream desync
    BlockOrdinalMismatch,
};

fn fnvFoldByte(h: u64, b: u8) u64 {
    return (h ^ b) *% 1099511628211;
}

fn fnvFoldInt(h: u64, value: u64, comptime byte_count: usize) u64 {
    var folded = h;
    inline for (0..byte_count) |i| {
        folded = fnvFoldByte(folded, @truncate(value >> (8 * i)));
    }
    return folded;
}

/// comptime FNV-1a 64 over the entity bit-widths and each component's identity
/// (serde_id if declared, else @typeName) and size, in tuple order
pub fn schemaHash(comptime types: anytype) u64 {
    comptime {
        @setEvalBranchQuota(types.len * 20_000 + 2_000);
        var h: u64 = 14695981039346656037;
        h = fnvFoldInt(h, @bitSizeOf(Entity.Index), 2);
        h = fnvFoldInt(h, @bitSizeOf(Entity.Version), 2);
        for (types) |T| {
            if (@hasDecl(T, "serde_id")) {
                h = fnvFoldByte(h, 0x01);
                h = fnvFoldInt(h, T.serde_id, 4);
            } else {
                h = fnvFoldByte(h, 0x00);
                for (@typeName(T)) |c| h = fnvFoldByte(h, c);
            }
            h = fnvFoldByte(h, 0x00);
            h = fnvFoldInt(h, @sizeOf(T), 4);
        }
        return h;
    }
}

pub fn writeHeader(archive: anytype, schema_hash: u64) void {
    archive.write(snapshot_magic);
    archive.write(snapshot_version);
    archive.write(@as(u16, 0)); // reserved
    archive.write(schema_hash);
}

pub fn readAndVerifyHeader(archive: anytype, expected_schema_hash: u64) SchemaError!void {
    if (archive.read(u32) != snapshot_magic) return error.InvalidMagic;
    if (archive.read(u16) > snapshot_version) return error.UnsupportedVersion;
    if (archive.read(u16) != 0) return error.ReservedFlagsSet;
    if (archive.read(u64) != expected_schema_hash) return error.SchemaMismatch;
}

/// dumps registry state into an archive. entt's basic_snapshot.
pub fn Snapshot(comptime Archive: type) type {
    return struct {
        const Self = @This();

        registry: *Registry,
        archive: *Archive,

        pub fn init(registry: *Registry, archive: *Archive) Self {
            return .{ .registry = registry, .archive = archive };
        }

        /// dumps the entity pool: live handles, dead-slot versions, and the
        /// free-chain order. must come first so loaders can validate entities
        /// before components arrive.
        pub fn entities(self: *Self) *Self {
            const h = &self.registry.handles;
            self.archive.write(@as(u64, h.append_cursor));
            self.archive.write(if (h.free_slot) |head| @as(u64, head) else @as(u64, Entity.null_index));
            for (h.handles[0..h.append_cursor]) |slot| {
                self.archive.write(slot);
            }
            return self;
        }

        /// dumps one component pool as (entity, value) pairs; zero-sized
        /// components write entities only. a pool the registry never created
        /// is written as count 0 (and is NOT created as a side effect).
        pub fn component(self: *Self, comptime T: type) *Self {
            const type_id = comptime utils.typeId(T);
            if (self.registry.components.get(type_id)) |ptr| {
                const store: *Storage(T) = @alignCast(@ptrCast(ptr));
                const ents = store.data();
                self.archive.write(@as(u64, @intCast(ents.len)));
                if (comptime @sizeOf(T) == 0) {
                    for (ents) |e| self.archive.write(e);
                } else {
                    for (ents, store.raw()) |e, value| {
                        self.archive.write(e);
                        self.archive.write(value);
                    }
                }
            } else {
                self.archive.write(@as(u64, 0));
            }
            return self;
        }

        /// header + entities + every component pool in tuple order, ordinal-tagged
        pub fn all(self: *Self, comptime types: anytype) void {
            comptime utils.assertNoTypeIdCollisions(types);
            writeHeader(self.archive, comptime schemaHash(types));
            _ = self.entities();
            inline for (types, 0..) |T, i| {
                self.archive.write(@as(u16, @intCast(i)));
                _ = self.component(T);
            }
        }
    };
}

/// restores a snapshot into a registry that has never allocated an entity,
/// preserving exact entity identifiers. entt's basic_snapshot_loader.
pub fn SnapshotLoader(comptime Archive: type) type {
    return struct {
        const Self = @This();

        registry: *Registry,
        archive: *Archive,

        pub fn init(registry: *Registry, archive: *Archive) Self {
            std.debug.assert(registry.handles.append_cursor == 0 and registry.handles.free_slot == null);
            return .{ .registry = registry, .archive = archive };
        }

        /// bulk-restores the entity pool bit-for-bit (writes the Handles fields
        /// directly — the wire IS the slot array, so no per-entity generate is
        /// needed and free-chain order survives). must run before component().
        pub fn entities(self: *Self) *Self {
            const count: usize = @intCast(self.archive.read(u64));
            const free_head = self.archive.read(u64);

            const h = &self.registry.handles;
            // keep create()'s `handles.len - 1 == append_cursor` grow trigger valid
            if (h.handles.len <= count) {
                h.handles = h.allocator.realloc(h.handles, count + 1) catch unreachable;
            }
            for (h.handles[0..count]) |*slot| {
                slot.* = self.archive.read(Entity);
            }
            h.append_cursor = @intCast(count);
            h.free_slot = if (free_head == Entity.null_index) null else @intCast(free_head);
            return self;
        }

        /// replays one component pool through Registry.add, so construction
        /// signals fire. requires entities() to have run (add asserts validity).
        pub fn component(self: *Self, comptime T: type) *Self {
            const count = self.archive.read(u64);
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                const e = self.archive.read(Entity);
                if (comptime @sizeOf(T) == 0) {
                    self.registry.add(e, std.mem.zeroes(T));
                } else {
                    self.registry.add(e, self.archive.read(T));
                }
            }
            return self;
        }

        /// verifies the header, then entities + every component pool in tuple order
        pub fn all(self: *Self, comptime types: anytype) SchemaError!void {
            comptime utils.assertNoTypeIdCollisions(types);
            try readAndVerifyHeader(self.archive, comptime schemaHash(types));
            _ = self.entities();
            inline for (types, 0..) |T, i| {
                if (self.archive.read(u16) != i) return error.BlockOrdinalMismatch;
                _ = self.component(T);
            }
        }
    };
}

/// true if T is Entity or (transitively) contains an Entity-typed field that
/// componentWithRefs would need to rewrite
fn containsEntityRefs(comptime T: type) bool {
    if (T == Entity) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| for (info.field_types) |FieldType| {
            if (containsEntityRefs(FieldType)) break true;
        } else false,
        .array => |info| containsEntityRefs(info.child),
        .optional => |info| containsEntityRefs(info.child),
        else => false,
    };
}

/// merges snapshots into a live registry, remapping remote entity ids to local
/// ones — the client-applying-server-updates primitive. keep one loader alive
/// for the lifetime of the connection: the remote→local table persists across
/// snapshots so repeated loads update entities in place, propagate remote
/// deaths, and recycle superseded locals. entt's basic_continuous_loader.
pub fn ContinuousLoader(comptime Archive: type) type {
    return struct {
        const Self = @This();

        pub const Remap = struct { remote: Entity, local: Entity };

        registry: *Registry,
        archive: *Archive,
        allocator: std.mem.Allocator,
        remloc: std.AutoHashMapUnmanaged(Entity.Index, Remap) = .empty,

        pub fn init(allocator: std.mem.Allocator, registry: *Registry, archive: *Archive) Self {
            return .{ .allocator = allocator, .registry = registry, .archive = archive };
        }

        pub fn deinit(self: *Self) void {
            self.remloc.deinit(self.allocator);
        }

        /// remote -> local, or null if the remote is unknown (or its local was
        /// destroyed out from under the loader)
        pub fn map(self: *const Self, remote: Entity) ?Entity {
            const remap = self.remloc.get(remote.index) orelse return null;
            if (remap.remote != remote) return null;
            if (!self.registry.valid(remap.local)) return null;
            return remap.local;
        }

        pub fn contains(self: *const Self, remote: Entity) bool {
            return self.map(remote) != null;
        }

        /// ensures `remote` has a live local twin. a remote index recycled at a
        /// new version supersedes the old mapping — the stale local is destroyed
        /// (entt leaks it when the death was never observed in a snapshot).
        fn restore(self: *Self, remote: Entity) void {
            const gop = self.remloc.getOrPut(self.allocator, remote.index) catch unreachable;
            if (gop.found_existing and gop.value_ptr.remote == remote) {
                if (!self.registry.valid(gop.value_ptr.local)) {
                    gop.value_ptr.local = self.registry.create();
                }
                return;
            }
            if (gop.found_existing and self.registry.valid(gop.value_ptr.local)) {
                self.registry.destroy(gop.value_ptr.local);
            }
            gop.value_ptr.* = .{ .remote = remote, .local = self.registry.create() };
        }

        /// consumes the entity pool dump: live remote slots get (or keep) a
        /// local twin; dead remote slots destroy their mapped local, if any
        pub fn entities(self: *Self) *Self {
            const count: usize = @intCast(self.archive.read(u64));
            _ = self.archive.read(u64); // free-chain head is meaningless across registries
            for (0..count) |i| {
                const slot = self.archive.read(Entity);
                if (slot.index == @as(Entity.Index, @intCast(i))) {
                    self.restore(slot);
                } else if (self.remloc.fetchRemove(@intCast(i))) |kv| {
                    if (self.registry.valid(kv.value.local)) {
                        self.registry.destroy(kv.value.local);
                    }
                }
            }
            return self;
        }

        /// merges one component pool. the incoming block is the complete truth
        /// for T among mapped entities: locals whose remote no longer carries T
        /// lose it (clean-slate strip), then every record is applied.
        pub fn component(self: *Self, comptime T: type) *Self {
            return self.componentImpl(T, false);
        }

        /// component() + rewrite Entity-typed fields (recursing through structs,
        /// fixed arrays, and optionals) from remote ids to local ids. dangling
        /// or unknown refs become Entity.null_entity; null refs stay untouched.
        /// unions and pointers are not walked — remap those via map() yourself.
        pub fn componentWithRefs(self: *Self, comptime T: type) *Self {
            return self.componentImpl(T, true);
        }

        fn componentImpl(self: *Self, comptime T: type, comptime remap_refs: bool) *Self {
            var strip = self.remloc.valueIterator();
            while (strip.next()) |remap| {
                if (self.registry.valid(remap.local)) {
                    self.registry.removeIfExists(T, remap.local);
                }
            }

            const count = self.archive.read(u64);
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                const remote = self.archive.read(Entity);
                self.restore(remote);
                const local = self.map(remote).?;
                if (comptime @sizeOf(T) == 0) {
                    self.registry.add(local, std.mem.zeroes(T));
                } else {
                    var value = self.archive.read(T);
                    if (comptime remap_refs) self.remapValue(T, &value);
                    self.registry.add(local, value);
                }
            }
            return self;
        }

        /// verifies the header, then entities + every component pool in tuple order
        pub fn all(self: *Self, comptime types: anytype) SchemaError!void {
            return self.allImpl(types, false);
        }

        /// all() with componentWithRefs semantics for every block
        pub fn allWithRefs(self: *Self, comptime types: anytype) SchemaError!void {
            return self.allImpl(types, true);
        }

        fn allImpl(self: *Self, comptime types: anytype, comptime remap_refs: bool) SchemaError!void {
            comptime utils.assertNoTypeIdCollisions(types);
            try readAndVerifyHeader(self.archive, comptime schemaHash(types));
            _ = self.entities();
            inline for (types, 0..) |T, i| {
                if (self.archive.read(u16) != i) return error.BlockOrdinalMismatch;
                _ = self.componentImpl(T, remap_refs);
            }
        }

        fn remapValue(self: *const Self, comptime T: type, value: *T) void {
            if (comptime T == Entity) {
                if (!value.isNull()) {
                    value.* = self.map(value.*) orelse Entity.null_entity;
                }
                return;
            }
            switch (@typeInfo(T)) {
                .@"struct" => |info| {
                    inline for (info.field_names, info.field_types, info.field_attrs) |name, FieldType, attrs| {
                        // copy out / write back instead of taking a field pointer
                        // so packed structs holding entities work too
                        if (comptime !attrs.@"comptime" and containsEntityRefs(FieldType)) {
                            var nested = @field(value.*, name);
                            self.remapValue(FieldType, &nested);
                            @field(value.*, name) = nested;
                        }
                    }
                },
                .array => |info| {
                    if (comptime containsEntityRefs(info.child)) {
                        for (value) |*element| self.remapValue(info.child, element);
                    }
                },
                .optional => |info| {
                    if (comptime containsEntityRefs(info.child)) {
                        if (value.*) |inner| {
                            var nested = inner;
                            self.remapValue(info.child, &nested);
                            value.* = nested;
                        }
                    }
                },
                else => {},
            }
        }
    };
}

/// reference archive: a growable in-memory byte buffer. integers and entities
/// are encoded little-endian; component values are copied in native layout, so
/// streams are only portable between binaries built from the same source for
/// the same target (the intended netcode setup — the schema hash enforces it).
pub const BasicBufferArchive = struct {
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    read_pos: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BasicBufferArchive {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BasicBufferArchive) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn write(self: *BasicBufferArchive, value: anytype) void {
        const T = @TypeOf(value);
        if (T == Entity) {
            self.writeInt(std.math.ByteAlignedInt(Entity.Backing), value.toIntegral());
        } else if (@typeInfo(T) == .int) {
            self.writeInt(std.math.ByteAlignedInt(T), value);
        } else {
            self.buffer.appendSlice(self.allocator, std.mem.asBytes(&value)) catch unreachable;
        }
    }

    pub fn read(self: *BasicBufferArchive, comptime T: type) T {
        if (T == Entity) {
            return Entity.fromIntegral(@intCast(self.readInt(std.math.ByteAlignedInt(Entity.Backing))));
        } else if (@typeInfo(T) == .int) {
            return @intCast(self.readInt(std.math.ByteAlignedInt(T)));
        } else {
            var value: T = undefined;
            const bytes = std.mem.asBytes(&value);
            @memcpy(bytes, self.buffer.items[self.read_pos..][0..bytes.len]);
            self.read_pos += bytes.len;
            return value;
        }
    }

    fn writeInt(self: *BasicBufferArchive, comptime I: type, value: I) void {
        var buf: [@divExact(@bitSizeOf(I), 8)]u8 = undefined;
        std.mem.writeInt(I, &buf, value, .little);
        self.buffer.appendSlice(self.allocator, &buf) catch unreachable;
    }

    fn readInt(self: *BasicBufferArchive, comptime I: type) I {
        const byte_count = @divExact(@bitSizeOf(I), 8);
        const value = std.mem.readInt(I, self.buffer.items[self.read_pos..][0..byte_count], .little);
        self.read_pos += byte_count;
        return value;
    }
};

test "schemaHash: order, size, and serde_id sensitivity" {
    const A = struct { x: f32 };
    const B = struct { x: f32, y: f32 };

    // order-sensitive
    comptime std.debug.assert(schemaHash(.{ A, B }) != schemaHash(.{ B, A }));
    // component-set-sensitive
    comptime std.debug.assert(schemaHash(.{A}) != schemaHash(.{ A, B }));

    // structurally identical types under different names differ...
    const C1 = struct { v: u32 };
    const C2 = struct { v: u32 };
    comptime std.debug.assert(schemaHash(.{C1}) != schemaHash(.{C2}));

    // ...unless they share a serde_id (rename immunity)
    const D1 = struct {
        pub const serde_id: u32 = 77;
        v: u32,
    };
    const D2 = struct {
        pub const serde_id: u32 = 77;
        v: u32,
    };
    comptime std.debug.assert(schemaHash(.{D1}) == schemaHash(.{D2}));
}

test "header round trip and rejection" {
    const types = .{struct { x: f32 }};
    const hash = comptime schemaHash(types);

    var ar = BasicBufferArchive.init(std.testing.allocator);
    defer ar.deinit();

    writeHeader(&ar, hash);
    try readAndVerifyHeader(&ar, hash);

    // wrong schema hash
    ar.read_pos = 0;
    try std.testing.expectError(error.SchemaMismatch, readAndVerifyHeader(&ar, hash +% 1));

    // corrupt magic
    var bad = BasicBufferArchive.init(std.testing.allocator);
    defer bad.deinit();
    bad.write(@as(u32, 0xDEADBEEF));
    bad.write(snapshot_version);
    bad.write(@as(u16, 0));
    bad.write(hash);
    try std.testing.expectError(error.InvalidMagic, readAndVerifyHeader(&bad, hash));

    // newer version
    bad.buffer.clearRetainingCapacity();
    bad.read_pos = 0;
    bad.write(snapshot_magic);
    bad.write(snapshot_version + 1);
    bad.write(@as(u16, 0));
    bad.write(hash);
    try std.testing.expectError(error.UnsupportedVersion, readAndVerifyHeader(&bad, hash));

    // reserved bits
    bad.buffer.clearRetainingCapacity();
    bad.read_pos = 0;
    bad.write(snapshot_magic);
    bad.write(snapshot_version);
    bad.write(@as(u16, 1));
    bad.write(hash);
    try std.testing.expectError(error.ReservedFlagsSet, readAndVerifyHeader(&bad, hash));
}
