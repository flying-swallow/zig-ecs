const std = @import("std");
const ecs = @import("ecs");
const Registry = ecs.Registry;
const Archive = ecs.BasicBufferArchive;

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Velocity = struct { x: f32 = 0, y: f32 = 0 };
const Tag = struct {};
const Unused = struct { v: u32 };

const all_types = .{ Position, Velocity, Tag, Unused };

test "snapshot: full round trip into a fresh registry" {
    var src = Registry.init(std.testing.allocator);
    defer src.deinit();

    // churn the pool so versions and the free chain are non-trivial:
    // kill two entities, recycle one slot at a bumped version
    var live: std.ArrayListUnmanaged(ecs.Entity) = .empty;
    defer live.deinit(std.testing.allocator);

    var created: [6]ecs.Entity = undefined;
    for (&created) |*e| e.* = src.create();
    src.destroy(created[1]);
    src.destroy(created[3]);
    const recycled = src.create();
    try std.testing.expect(recycled.version != 0);

    for (created, 0..) |e, i| {
        if (i != 1 and i != 3) try live.append(std.testing.allocator, e);
    }
    try live.append(std.testing.allocator, recycled);

    for (live.items, 0..) |e, i| {
        src.add(e, Position{ .x = @floatFromInt(i), .y = 2 * @as(f32, @floatFromInt(i)) });
        if (i % 2 == 0) src.add(e, Velocity{ .x = -1, .y = @floatFromInt(i) });
        if (i % 3 == 0) src.add(e, Tag{});
    }

    var ar = Archive.init(std.testing.allocator);
    defer ar.deinit();
    var snap = ecs.Snapshot(Archive).init(&src, &ar);
    snap.all(all_types);

    var dst = Registry.init(std.testing.allocator);
    defer dst.deinit();
    var loader = ecs.SnapshotLoader(Archive).init(&dst, &ar);
    try loader.all(all_types);

    // every live source entity is valid in the destination with identical bits
    // and identical components
    for (live.items, 0..) |e, i| {
        try std.testing.expect(dst.valid(e));
        try std.testing.expectEqual(src.getConst(Position, e), dst.getConst(Position, e));
        try std.testing.expectEqual(i % 2 == 0, dst.has(Velocity, e));
        try std.testing.expectEqual(i % 3 == 0, dst.has(Tag, e));
        try std.testing.expect(!dst.has(Unused, e));
    }

    // dead source entities stay dead in the destination
    try std.testing.expect(!dst.valid(created[1]));
    try std.testing.expect(!dst.valid(created[3]));

    // recycling determinism: dead-slot versions and free-chain order survived,
    // so both registries hand out bit-identical handles from here on
    for (0..3) |_| {
        try std.testing.expectEqual(src.create(), dst.create());
    }
}

test "snapshot: loading into a registry with an owning group" {
    var src = Registry.init(std.testing.allocator);
    defer src.deinit();

    var expected_members: usize = 0;
    for (0..5) |i| {
        const e = src.create();
        src.add(e, Position{ .x = @floatFromInt(i) });
        if (i % 2 == 0) {
            src.add(e, Velocity{ .y = @floatFromInt(i) });
            expected_members += 1;
        }
    }

    var ar = Archive.init(std.testing.allocator);
    defer ar.deinit();
    var snap = ecs.Snapshot(Archive).init(&src, &ar);
    snap.all(.{ Position, Velocity });

    var dst = Registry.init(std.testing.allocator);
    defer dst.deinit();
    // register the owning group BEFORE loading; construction signals fired by
    // the loader drive the group's swap-packing
    const group = dst.group(.{ Position, Velocity }, .{}, .{});

    var loader = ecs.SnapshotLoader(Archive).init(&dst, &ar);
    try loader.all(.{ Position, Velocity });

    try std.testing.expectEqual(expected_members, group.len());
    // group members are the packed prefix of the first owned storage
    for (group.data()[0..group.len()]) |e| {
        try std.testing.expect(dst.has(Position, e));
        try std.testing.expect(dst.has(Velocity, e));
        try std.testing.expectEqual(src.getConst(Position, e), dst.getConst(Position, e));
        try std.testing.expectEqual(src.getConst(Velocity, e), dst.getConst(Velocity, e));
    }
}

test "snapshot: schema mismatch is rejected" {
    var src = Registry.init(std.testing.allocator);
    defer src.deinit();
    _ = src.create();

    var ar = Archive.init(std.testing.allocator);
    defer ar.deinit();
    var snap = ecs.Snapshot(Archive).init(&src, &ar);
    snap.all(.{Position});

    // loader expects a different component set
    var dst = Registry.init(std.testing.allocator);
    defer dst.deinit();
    var loader = ecs.SnapshotLoader(Archive).init(&dst, &ar);
    try std.testing.expectError(error.SchemaMismatch, loader.all(.{ Position, Velocity }));
}

test "snapshot: component block out of order is rejected" {
    var src = Registry.init(std.testing.allocator);
    defer src.deinit();

    var ar = Archive.init(std.testing.allocator);
    defer ar.deinit();

    // hand-write a stream whose first block carries the wrong ordinal
    ecs.snapshot.writeHeader(&ar, comptime ecs.snapshot.schemaHash(.{Position}));
    var snap = ecs.Snapshot(Archive).init(&src, &ar);
    _ = snap.entities();
    ar.write(@as(u16, 1));
    _ = snap.component(Position);

    var dst = Registry.init(std.testing.allocator);
    defer dst.deinit();
    var loader = ecs.SnapshotLoader(Archive).init(&dst, &ar);
    try std.testing.expectError(error.BlockOrdinalMismatch, loader.all(.{Position}));
}

const Parent = struct { child: ecs.Entity };

test "continuous loader: remaps entities and entity references" {
    var src = Registry.init(std.testing.allocator);
    defer src.deinit();

    const a = src.create();
    const b = src.create();
    const stale = src.create();
    src.destroy(stale);
    const c = src.create(); // recycles stale's index at a new version

    src.add(a, Parent{ .child = b });
    src.add(b, Parent{ .child = ecs.Entity.null_entity });
    src.add(c, Parent{ .child = stale }); // dangling: refers to the dead version

    var ar = Archive.init(std.testing.allocator);
    defer ar.deinit();
    var snap = ecs.Snapshot(Archive).init(&src, &ar);
    snap.all(.{Parent});

    // pre-populate the destination so local ids cannot equal remote ids
    var dst = Registry.init(std.testing.allocator);
    defer dst.deinit();
    for (0..4) |_| _ = dst.create();

    var loader = ecs.ContinuousLoader(Archive).init(std.testing.allocator, &dst, &ar);
    defer loader.deinit();
    try loader.allWithRefs(.{Parent});

    const la = loader.map(a).?;
    const lb = loader.map(b).?;
    const lc = loader.map(c).?;
    try std.testing.expect(dst.valid(la) and dst.valid(lb) and dst.valid(lc));
    try std.testing.expect(la.index != a.index); // actually remapped

    // cross-reference rewritten to the local twin
    try std.testing.expectEqual(lb, dst.getConst(Parent, la).child);
    // explicit null stays null
    try std.testing.expect(dst.getConst(Parent, lb).child.isNull());
    // dangling remote becomes null_entity
    try std.testing.expectEqual(ecs.Entity.null_entity, dst.getConst(Parent, lc).child);
    // the dead remote version is unknown to the loader
    try std.testing.expectEqual(null, loader.map(stale));
}

test "continuous loader: repeated snapshots propagate deaths and updates" {
    var src = Registry.init(std.testing.allocator);
    defer src.deinit();

    const e0 = src.create();
    const e1 = src.create();
    const e3 = src.create();
    src.add(e0, Position{ .x = 1 });
    src.add(e1, Position{ .x = 2 });
    src.add(e3, Position{ .x = 3 });
    src.add(e1, Tag{});

    var dst = Registry.init(std.testing.allocator);
    defer dst.deinit();
    for (0..2) |_| _ = dst.create();

    // first snapshot
    var ar1 = Archive.init(std.testing.allocator);
    defer ar1.deinit();
    var snap1 = ecs.Snapshot(Archive).init(&src, &ar1);
    snap1.all(.{ Position, Tag });

    var loader = ecs.ContinuousLoader(Archive).init(std.testing.allocator, &dst, &ar1);
    defer loader.deinit();
    try loader.all(.{ Position, Tag });

    const l0 = loader.map(e0).?;
    const l1 = loader.map(e1).?;
    const l3 = loader.map(e3).?;
    try std.testing.expectEqual(@as(f32, 2), dst.getConst(Position, l1).x);
    try std.testing.expect(dst.has(Tag, l1));

    // mutate the source: e0 dies and its slot is recycled by e2 (supersede
    // path), e3 dies without recycling (dead-slot path), e1 changes in place
    src.destroy(e0);
    const e2 = src.create();
    try std.testing.expectEqual(e0.index, e2.index);
    src.add(e2, Position{ .x = 30 });
    src.replace(e1, Position{ .x = 20 });
    src.remove(Tag, e1);
    src.destroy(e3);

    // second snapshot through the SAME loader
    var ar2 = Archive.init(std.testing.allocator);
    defer ar2.deinit();
    var snap2 = ecs.Snapshot(Archive).init(&src, &ar2);
    snap2.all(.{ Position, Tag });

    loader.archive = &ar2;
    try loader.all(.{ Position, Tag });

    // superseded: e0's local was destroyed, e2 got a fresh one
    try std.testing.expectEqual(null, loader.map(e0));
    try std.testing.expect(!dst.valid(l0));
    const l2 = loader.map(e2).?;
    try std.testing.expect(dst.valid(l2));
    try std.testing.expectEqual(@as(f32, 30), dst.getConst(Position, l2).x);

    // dead slot propagated: e3's local died with it
    try std.testing.expectEqual(null, loader.map(e3));
    try std.testing.expect(!dst.valid(l3));

    // stable mapping updated in place; the stripped Tag is gone
    try std.testing.expectEqual(l1, loader.map(e1).?);
    try std.testing.expectEqual(@as(f32, 20), dst.getConst(Position, l1).x);
    try std.testing.expect(!dst.has(Tag, l1));
}
