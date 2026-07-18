const std = @import("std");

/// default Entity with reasonable sizes suitable for most situations
pub const DefaultEntity = EntityClass(.medium);

pub const EntityParameters = struct {
    index_bits: usize,
    version_bits: usize,
    pub const small: @This() = .{ .index_bits = 12, .version_bits = 4 };
    pub const medium: @This() = .{ .index_bits = 20, .version_bits = 12 };
    pub const large: @This() = .{ .index_bits = 32, .version_bits = 32 };
};

pub fn EntityClass(comptime entity_parameters: EntityParameters) type {
    const total_bits = entity_parameters.index_bits + entity_parameters.version_bits;
    const EntityBackingInt = @Int(.unsigned, total_bits);

    return packed struct(EntityBackingInt) {
        pub const Index = @Int(.unsigned, entity_parameters.index_bits);
        pub const Version = @Int(.unsigned, entity_parameters.version_bits);

        /// the flat integer type backing this entity (for archives / bit-casting)
        pub const Backing = EntityBackingInt;

        /// reserved all-ones index: never issued by Handles (it doubles as
        /// Handles' free-list terminator), so it is safe as a "no entity" tag
        pub const null_index: Index = std.math.maxInt(Index);
        pub const null_version: Version = std.math.maxInt(Version);

        /// canonical "no entity" value (both parts saturated, matching entt's
        /// null/tombstone bit pattern). NOTE: Handles.remove wraps versions
        /// with +% and deliberately does NOT reserve null_version — null
        /// detection must go through isNull (index part), which is unique.
        pub const null_entity: @This() = .{ .index = null_index, .version = null_version };

        index: Index,
        version: Version,

        /// entt-style null comparison: inspects only the index part, so any
        /// version paired with null_index still reads as null
        pub fn isNull(self: @This()) bool {
            return self.index == null_index;
        }

        pub fn toIntegral(self: @This()) Backing {
            return @bitCast(self);
        }

        pub fn fromIntegral(value: Backing) @This() {
            return @bitCast(value);
        }

        pub fn formatNumber(value: @This(), writer: *std.Io.Writer, number: std.fmt.Number) std.Io.Writer.Error!void {
            return writer.printIntAny(
                @as(EntityBackingInt, @bitCast(value)),
                switch (number.mode) {
                    .decimal => 10,
                    .binary => 2,
                    .octal => 8,
                    .hex => 16,
                    .scientific => 10,
                },
                number.case,
                .{
                    .width = number.width,
                    .alignment = number.alignment,
                    .fill = number.fill,
                    .precision = null,
                },
            );
        }
    };
}

test EntityClass {
    const Small = EntityClass(.small);
    const Medium = EntityClass(.medium);
    const Large = EntityClass(.large);

    try std.testing.expectEqual(Small.Index, u12);
    try std.testing.expectEqual(Medium.Index, u20);
    try std.testing.expectEqual(Large.Index, u32);
}

test "entity backing widths" {
    try std.testing.expectEqual(u16, EntityClass(.small).Backing);
    try std.testing.expectEqual(u32, EntityClass(.medium).Backing);
    try std.testing.expectEqual(u64, EntityClass(.large).Backing);
}

test "entity null sentinel" {
    const E = EntityClass(.medium);

    // both parts saturated == all bits set
    try std.testing.expectEqual(std.math.maxInt(E.Backing), E.null_entity.toIntegral());
    try std.testing.expect(E.null_entity.isNull());

    // isNull inspects only the index part
    try std.testing.expect((E{ .index = E.null_index, .version = 0 }).isNull());
    try std.testing.expect(!(E{ .index = 0, .version = E.null_version }).isNull());
    try std.testing.expect(!(E{ .index = 42, .version = 7 }).isNull());
}

test "entity integral round trip" {
    const E = EntityClass(.small);

    const e = E{ .index = 299, .version = 15 };
    try std.testing.expectEqual(e, E.fromIntegral(e.toIntegral()));

    // index occupies the low bits, version the high bits
    const bits: E.Backing = e.toIntegral();
    try std.testing.expectEqual(@as(E.Index, 299), @as(E.Index, @truncate(bits)));
    try std.testing.expectEqual(@as(E.Version, 15), @as(E.Version, @intCast(bits >> 12)));
}
