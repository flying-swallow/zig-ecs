const std = @import("std");
const registry = @import("registry.zig");

/// generates versioned "handles" (https://floooh.github.io/2018/06/17/handles-vs-pointers.html)
/// you choose the type of the handle (aka its size) and how much of that goes to the index and the version.
/// the bitsize of version + id must equal the handle size.
pub fn Handles(comptime HandleType: type) type {
    return struct {
        const Self = @This();

        handles: []HandleType,
        /// When creating a new entity, if there are no free slots (indicated by last_destroyed being null),
        /// create a new entity at this index
        append_cursor: HandleType.Index = 0,
        /// A linked list of unused slots
        /// This field points to the index of the latest freed slot
        /// The index of the next free slot is stored in the `index` field of the handle
        free_slot: ?HandleType.Index = null,
        allocator: std.mem.Allocator,

        pub const max_active_entities = std.math.maxInt(HandleType.Index);
        /// free-list terminator; equals HandleType.null_index, so the all-ones
        /// index is never issued as a live handle
        const invalid_id = std.math.maxInt(HandleType.Index);

        pub const Iterator = struct {
            hm: Self,
            index: usize = 0,

            pub fn init(hm: Self) @This() {
                return .{ .hm = hm };
            }

            pub fn next(self: *@This()) ?HandleType {
                if (self.index == self.hm.append_cursor) return null;

                for (self.hm.handles[self.index..self.hm.append_cursor]) |h| {
                    self.index += 1;
                    if (self.hm.alive(h)) {
                        return h;
                    }
                }
                return null;
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return initWithCapacity(allocator, 32);
        }

        pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) Self {
            return .{
                .handles = allocator.alloc(HandleType, capacity) catch unreachable,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.handles);
        }

        pub fn create(self: *Self) !HandleType {
            // we have a free slot, consume it
            if (self.free_slot) |free_index| {
                const version = self.handles[free_index].version;
                // the index of the next free slot
                const next_free_index = self.handles[free_index].index;

                const handle: HandleType = .{ .index = free_index, .version = version };
                self.handles[free_index] = handle;

                // set the head of our linked list to point at the next free index
                self.free_slot = if (next_free_index == invalid_id) null else next_free_index;

                return handle;
            }

            // we have no free slots, so append to the end of array

            // we are out of handles that can be active at once
            if (self.append_cursor == invalid_id) return error.OutOfActiveHandles;

            // ensure capacity and grow if needed
            if (self.handles.len - 1 == self.append_cursor) {
                self.handles = self.allocator.realloc(self.handles, @min(max_active_entities, self.handles.len * 2)) catch unreachable;
            }

            const handle: HandleType = .{ .index = @intCast(self.append_cursor), .version = 0 };
            self.handles[self.append_cursor] = handle;

            self.append_cursor += 1;
            return handle;
        }

        pub fn remove(self: *Self, handle: HandleType) !void {
            const index = handle.index;
            if (!self.alive(handle)) return error.RemovedInvalidHandle;

            // point entry at next free slot
            // TODO: Do not allow overflow, permanently retire entity instead
            self.handles[index] = .{ .index = self.free_slot orelse invalid_id, .version = handle.version +% 1 };

            self.free_slot = index;
        }

        pub const GenerateError = error{ InvalidHandle, AlreadyExists };

        /// forces `handle` (caller-chosen index AND version) to become alive, e.g. to
        /// restore identifiers from a snapshot or spawn prefabs with fixed ids.
        /// never-used slots below handle.index join the free list with pending
        /// version 0, chained in ascending index order ahead of the existing chain.
        pub fn generate(self: *Self, handle: HandleType) GenerateError!void {
            const idx = handle.index;
            // the all-ones index is the free-list terminator and can never be alive
            if (idx == invalid_id) return error.InvalidHandle;

            if (idx < self.append_cursor) {
                // live slots are self-referential; free slots never point at themselves
                if (self.handles[idx].index == idx) return error.AlreadyExists;

                // slot is on the free chain: unlink it (singly linked, so walk to it)
                const next = self.handles[idx].index;
                if (self.free_slot.? == idx) {
                    self.free_slot = if (next == invalid_id) null else next;
                } else {
                    var prev = self.free_slot.?;
                    while (self.handles[prev].index != idx) : (prev = self.handles[prev].index) {}
                    self.handles[prev].index = next;
                }
                self.handles[idx] = handle;
                return;
            }

            // idx >= append_cursor: grow so that handles.len > the new append_cursor,
            // preserving create()'s `handles.len - 1 == append_cursor` grow trigger
            if (self.handles.len <= @as(usize, idx) + 1) {
                const new_len = @min(
                    @as(usize, max_active_entities),
                    @max(self.handles.len * 2, @as(usize, idx) + 2),
                );
                self.handles = self.allocator.realloc(self.handles, new_len) catch unreachable;
            }

            // gap slots [append_cursor, idx) become free-chain members with pending
            // version 0, ascending, the tail pointing at the previous chain head
            if (idx > self.append_cursor) {
                var i: HandleType.Index = self.append_cursor;
                while (i < idx - 1) : (i += 1) {
                    self.handles[i] = .{ .index = i + 1, .version = 0 };
                }
                self.handles[idx - 1] = .{ .index = self.free_slot orelse invalid_id, .version = 0 };
                self.free_slot = self.append_cursor;
            }

            self.handles[idx] = handle;
            self.append_cursor = idx + 1;
        }

        pub fn alive(self: Self, handle: HandleType) bool {
            return
            // we couldn't possibly have allocated this handle yet
            handle.index < self.append_cursor and
                // when we hand out a... handle, we always set the corresponding slot in the array to the handle
                // when we free it, we use the handle's index field as a index to the next free slot (or maxInt
                // if no other free slots exist), so double-frees are always caught
                self.handles[handle.index] == handle;
        }

        pub fn iterator(self: Self) Iterator {
            return Iterator.init(self);
        }
    };
}

test "handles" {
    const entity = @import("entity.zig");

    var handles: Handles(entity.EntityClass(.{
        .index_bits = 4,
        .version_bits = 4,
    })) = .init(std.testing.allocator);
    defer handles.deinit();

    const e0 = try handles.create();
    const e1 = try handles.create();
    const e2 = try handles.create();

    std.debug.assert(handles.alive(e0));
    std.debug.assert(handles.alive(e1));
    std.debug.assert(handles.alive(e2));

    handles.remove(e1) catch unreachable;
    std.debug.assert(!handles.alive(e1));

    try std.testing.expectError(error.RemovedInvalidHandle, handles.remove(e1));

    var e_tmp = try handles.create();
    std.debug.assert(handles.alive(e_tmp));

    handles.remove(e_tmp) catch unreachable;
    std.debug.assert(!handles.alive(e_tmp));

    handles.remove(e0) catch unreachable;
    std.debug.assert(!handles.alive(e0));

    handles.remove(e2) catch unreachable;
    std.debug.assert(!handles.alive(e2));

    e_tmp = try handles.create();
    std.debug.assert(handles.alive(e_tmp));

    e_tmp = try handles.create();
    std.debug.assert(handles.alive(e_tmp));

    e_tmp = try handles.create();
    std.debug.assert(handles.alive(e_tmp));
}

const TestEntity = @import("entity.zig").EntityClass(.{ .index_bits = 4, .version_bits = 4 });

test "generate: append and gap fill" {
    var handles: Handles(TestEntity) = .init(std.testing.allocator);
    defer handles.deinit();

    // into an empty pool at index 0 == plain append
    try handles.generate(.{ .index = 0, .version = 9 });
    try std.testing.expect(handles.alive(.{ .index = 0, .version = 9 }));

    // with a gap: slots 1 and 2 must join the free list in ascending order
    try handles.generate(.{ .index = 3, .version = 2 });
    try std.testing.expect(handles.alive(.{ .index = 3, .version = 2 }));

    const g1 = try handles.create();
    const g2 = try handles.create();
    try std.testing.expectEqual(TestEntity{ .index = 1, .version = 0 }, g1);
    try std.testing.expectEqual(TestEntity{ .index = 2, .version = 0 }, g2);

    // gap drained: next create appends past the generated slot
    const g3 = try handles.create();
    try std.testing.expectEqual(TestEntity{ .index = 4, .version = 0 }, g3);
}

test "generate: errors" {
    var handles: Handles(TestEntity) = .init(std.testing.allocator);
    defer handles.deinit();

    const e0 = try handles.create();
    try std.testing.expectError(error.AlreadyExists, handles.generate(e0));
    try std.testing.expectError(error.AlreadyExists, handles.generate(.{ .index = e0.index, .version = e0.version +% 3 }));
    try std.testing.expectError(error.InvalidHandle, handles.generate(.{ .index = TestEntity.null_index, .version = 0 }));
}

test "generate: revive a freed slot with a chosen version" {
    var handles: Handles(TestEntity) = .init(std.testing.allocator);
    defer handles.deinit();

    const e0 = try handles.create();
    const e1 = try handles.create();
    try handles.remove(e0);

    try handles.generate(.{ .index = e0.index, .version = 7 });
    try std.testing.expect(handles.alive(.{ .index = e0.index, .version = 7 }));
    try std.testing.expect(!handles.alive(e0));
    try std.testing.expect(handles.alive(e1));

    // the freed slot was the chain head; chain must now be empty
    const e2 = try handles.create();
    try std.testing.expectEqual(@as(TestEntity.Index, 2), e2.index);
}

test "generate: unlink at head, middle, and tail of the free chain" {
    // build a 3-slot free chain, unlink each position, drain and check uniqueness
    for (0..3) |target| {
        var handles: Handles(TestEntity) = .init(std.testing.allocator);
        defer handles.deinit();

        var created: [4]TestEntity = undefined;
        for (&created) |*e| e.* = try handles.create();
        // free 0,1,2 -> chain head is 2 -> 1 -> 0
        for (created[0..3]) |e| try handles.remove(e);

        try handles.generate(.{ .index = @intCast(target), .version = 9 });
        try std.testing.expect(handles.alive(.{ .index = @intCast(target), .version = 9 }));

        // drain the two remaining free slots plus one appended slot
        var seen: [8]bool = @splat(false);
        seen[target] = true;
        seen[3] = true; // created[3] is still alive
        for (0..3) |_| {
            const e = try handles.create();
            try std.testing.expect(!seen[e.index]);
            seen[e.index] = true;
        }
        // everything below the cursor plus the append slot is now accounted for
        try std.testing.expect(seen[0] and seen[1] and seen[2] and seen[4]);
    }
}
