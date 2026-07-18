//! dirty-tracking recorder: a set of entities whose component was constructed,
//! updated, and/or destroyed since the last clear(). This is the delta-netcode
//! primitive — serialize just the recorded set instead of full snapshots.
//! Mirrors entt 4.0's basic_reactive_mixin via composition.
//!
//! Usage — one instance per record you want; chain the sinks you care about:
//!
//!     var dirty = ecs.ReactiveStorage(Position, ecs.Entity).create(allocator);
//!     var removed = ecs.ReactiveStorage(Position, ecs.Entity).create(allocator);
//!     // destroy BEFORE the registry deinits (the source storages must outlive
//!     // the connections):
//!     defer removed.destroy();
//!     defer dirty.destroy();
//!
//!     _ = dirty.onConstruct(reg.assure(Position)).onUpdate(reg.assure(Position));
//!     _ = removed.onDestruct(reg.assure(Position));
//!
//!     // ... frame: reg.add / reg.replace / reg.notifyUpdated(Position, e) / reg.destroy(e) ...
//!     for (dirty.data()) |e| { ... send create/update ... }
//!     for (removed.data()) |e| { ... send remove ... }
//!     dirty.clear();
//!     removed.clear();
//!
//! Contracts:
//! - Mutations only register when they go through the signalling path:
//!   `replace`, `addOrReplace`, or `registry.notifyUpdated(T, e)` after an
//!   in-place `get()` edit. Raw `get().*` writes fire no update signal.
//! - Consume and clear() every window, before destroyed entity ids can be
//!   recycled — the record dedupes by entity index, so a recycled id would
//!   otherwise be shadowed by its dead predecessor.
//! - connectBound stores this struct's address: use create()/destroy() (or a
//!   pinned var) — the instance must not move while connected.

const std = @import("std");
const SparseSet = @import("sparse_set.zig").SparseSet;
const ComponentStorage = @import("component_storage.zig").ComponentStorage;
const Registry = @import("registry.zig").Registry;
const ReverseSliceIterator = @import("utils.zig").ReverseSliceIterator;

pub fn ReactiveStorage(comptime Component: type, comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Source = ComponentStorage(Component, Entity);

        set: SparseSet(Entity),
        /// the one storage this instance records from (single-source for now)
        source: ?*Source = null,
        allocator: std.mem.Allocator,

        /// heap-allocates for a stable address — the primary way to build one
        pub fn create(allocator: std.mem.Allocator) *Self {
            const reactive = allocator.create(Self) catch unreachable;
            reactive.* = Self.init(allocator);
            return reactive;
        }

        /// disconnects, deinits, and frees a create()d instance
        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.deinit();
            allocator.destroy(self);
        }

        /// value form; the instance must not move once connected
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .set = SparseSet(Entity).init(allocator), .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.disconnect();
            self.set.deinit();
        }

        /// record entities whose component gets constructed. chainable.
        pub fn onConstruct(self: *Self, source: *Source) *Self {
            self.attach(source);
            source.onConstruct().connectBound(self, Self.record);
            return self;
        }

        /// record entities whose component gets updated (via the signalling
        /// path — see the module doc). chainable.
        pub fn onUpdate(self: *Self, source: *Source) *Self {
            self.attach(source);
            source.onUpdate().connectBound(self, Self.record);
            return self;
        }

        /// record entities whose component gets removed/destroyed. the signal
        /// fires before removal, but the record keeps only the id. chainable.
        pub fn onDestruct(self: *Self, source: *Source) *Self {
            self.attach(source);
            source.onDestruct().connectBound(self, Self.record);
            return self;
        }

        fn attach(self: *Self, source: *Source) void {
            std.debug.assert(self.source == null or self.source == source);
            self.source = source;
        }

        fn record(self: *Self, _: *Registry, entity: Entity) void {
            // the same entity may fire several signals per window
            if (!self.set.contains(entity)) {
                self.set.add(entity);
            }
        }

        /// the recorded entities, in recording order
        pub fn data(self: Self) []const Entity {
            return self.set.data();
        }

        pub fn contains(self: Self, entity: Entity) bool {
            return self.set.contains(entity);
        }

        pub fn len(self: Self) usize {
            return self.set.len();
        }

        pub fn entityIterator(self: *Self) ReverseSliceIterator(Entity) {
            return self.set.reverseIterator();
        }

        /// empties the record; connections stay live for the next window
        pub fn clear(self: *Self) void {
            self.set.clear();
        }

        /// detaches from the source's sinks (harmless where not connected) and
        /// forgets the source. must run while the source storage is still alive.
        pub fn disconnect(self: *Self) void {
            if (self.source) |source| {
                source.onConstruct().disconnectBound(self);
                source.onUpdate().disconnectBound(self);
                source.onDestruct().disconnectBound(self);
                self.source = null;
            }
        }
    };
}

const DefaultEntity = @import("entity.zig").DefaultEntity;

test "reactive: records construct, update, and destruct separately" {
    var store = ComponentStorage(f32, DefaultEntity).init(std.testing.allocator);
    defer store.deinit();

    var constructed = ReactiveStorage(f32, DefaultEntity).init(std.testing.allocator);
    defer constructed.deinit();
    var updated = ReactiveStorage(f32, DefaultEntity).init(std.testing.allocator);
    defer updated.deinit();
    var removed = ReactiveStorage(f32, DefaultEntity).init(std.testing.allocator);
    defer removed.deinit();

    _ = constructed.onConstruct(&store);
    _ = updated.onUpdate(&store);
    _ = removed.onDestruct(&store);

    const e3 = DefaultEntity{ .index = 3, .version = 0 };
    const e4 = DefaultEntity{ .index = 4, .version = 0 };

    store.add(e3, 1.0);
    store.add(e4, 2.0);
    store.replace(e3, 1.5);
    store.remove(e4);

    try std.testing.expectEqual(@as(usize, 2), constructed.len());
    try std.testing.expect(constructed.contains(e3) and constructed.contains(e4));
    try std.testing.expectEqual(@as(usize, 1), updated.len());
    try std.testing.expect(updated.contains(e3));
    try std.testing.expectEqual(@as(usize, 1), removed.len());
    try std.testing.expect(removed.contains(e4));
}

test "reactive: dedupes repeated events for the same entity" {
    var store = ComponentStorage(f32, DefaultEntity).init(std.testing.allocator);
    defer store.deinit();

    var dirty = ReactiveStorage(f32, DefaultEntity).init(std.testing.allocator);
    defer dirty.deinit();
    _ = dirty.onConstruct(&store).onUpdate(&store);

    const e = DefaultEntity{ .index = 7, .version = 0 };
    store.add(e, 1.0);
    store.replace(e, 2.0);
    store.replace(e, 3.0);

    try std.testing.expectEqual(@as(usize, 1), dirty.len());
}

test "reactive: clear keeps connections, disconnect stops recording" {
    var store = ComponentStorage(f32, DefaultEntity).init(std.testing.allocator);
    defer store.deinit();

    var dirty = ReactiveStorage(f32, DefaultEntity).init(std.testing.allocator);
    defer dirty.deinit();
    _ = dirty.onUpdate(&store);

    const e = DefaultEntity{ .index = 1, .version = 0 };
    store.add(e, 1.0);
    try std.testing.expectEqual(@as(usize, 0), dirty.len()); // construct not chained

    store.replace(e, 2.0);
    try std.testing.expectEqual(@as(usize, 1), dirty.len());

    dirty.clear();
    try std.testing.expectEqual(@as(usize, 0), dirty.len());
    store.replace(e, 3.0);
    try std.testing.expectEqual(@as(usize, 1), dirty.len()); // still recording

    dirty.disconnect();
    dirty.clear();
    store.replace(e, 4.0);
    try std.testing.expectEqual(@as(usize, 0), dirty.len()); // detached
    // second disconnect/deinit is harmless
    dirty.disconnect();
}

test "reactive: registry integration incl. destroy path" {
    const Position = struct { x: f32 = 0, y: f32 = 0 };
    const RegistryEntity = @import("registry.zig").Entity;

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const dirty = ReactiveStorage(Position, RegistryEntity).create(std.testing.allocator);
    defer dirty.destroy();
    const removed = ReactiveStorage(Position, RegistryEntity).create(std.testing.allocator);
    defer removed.destroy();

    _ = dirty.onConstruct(reg.assure(Position)).onUpdate(reg.assure(Position));
    _ = removed.onDestruct(reg.assure(Position));

    const e1 = reg.create();
    const e2 = reg.create();
    reg.add(e1, Position{ .x = 1 });
    reg.add(e2, Position{ .x = 2 });
    _ = reg.get(Position, e1).x; // raw get fires nothing
    reg.notifyUpdated(Position, e1);
    reg.destroy(e2); // removeAllComponents publishes destruction

    try std.testing.expectEqual(@as(usize, 2), dirty.len());
    try std.testing.expect(dirty.contains(e1) and dirty.contains(e2));
    try std.testing.expectEqual(@as(usize, 1), removed.len());
    try std.testing.expect(removed.contains(e2));

    // window boundary: consume + clear, then only new events register
    dirty.clear();
    removed.clear();
    reg.replace(e1, Position{ .x = 5 });
    try std.testing.expectEqual(@as(usize, 1), dirty.len());
    try std.testing.expectEqual(@as(usize, 0), removed.len());
}
