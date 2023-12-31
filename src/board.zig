const std = @import("std");
const Errors = @import("errors.zig");

const Self = @This();

// Grid state variables
grid_x: u8 = 1,
grid_y: u8 = 1,
grid_buffer: [144]u8 = [_]u8{0} ** 144,

pub fn init(grid_x: u8, grid_y: u8) Errors.GameError!Self {
    if (grid_x * grid_y > 144) {
        return Errors.GameError.GridTooBig;
    }

    return Self{
        .grid_x = grid_x,
        .grid_y = grid_y,
    };
}

pub fn clear(self: *Self) void {
    @memset(&self.grid_buffer, 0);
}

fn offset(self: *Self, x: usize, y: usize) usize {
    return x + (y * self.grid_x);
}

pub fn get(self: *Self, x: usize, y: usize) Errors.GameError!u8 {
    if (x < 0 or y < 0 or x >= self.grid_x or y >= self.grid_y) {
        return Errors.GameError.InvalidBoardPosition;
    }
    return self.grid_buffer[self.offset(x, y)];
}

pub fn put(self: *Self, x: usize, y: usize, value: u8) Errors.GameError!void {
    if (x < 0 or y < 0 or x >= self.grid_x or y >= self.grid_y) {
        return Errors.GameError.InvalidBoardPosition;
    }
    const o = self.offset(x, y);
    std.log.debug("doing a put at {},{}:{} -> {}", .{ x, y, o, value });
    self.grid_buffer[o] = value;
}

pub fn nuke(self: *Self, x: usize, y: usize) Errors.GameError!void {
    if (x < 0 or y < 0 or x >= self.grid_x or y >= self.grid_y) {
        return Errors.GameError.InvalidBoardPosition;
    }
    std.log.debug("dropping a nuke at {},{}", .{ x, y });
    // nuke this square, and all the adjacent squares
    self.put(x, y, 0) catch {};
    self.put(x + 1, y, 0) catch {};
    self.put(x + 1, y + 1, 0) catch {};
    self.put(x, y + 1, 0) catch {};
    if (x > 0) {
        self.put(x -| 1, y, 0) catch {};
        self.put(x -| 1, y + 1, 0) catch {};
    }
    if (y > 0) {
        self.put(x, y -| 1, 0) catch {};
        self.put(x + 1, y -| 1, 0) catch {};
        if (x > 0) {
            self.put(x -| 1, y -| 1, 0) catch {};
        }
    }
}

pub fn victory(self: *Self, player: u8, runlength: u8) bool {
    std.log.debug("victory check for player {} with runlength {}", .{ player, runlength });
    var pos: usize = 0;
    for (0..self.grid_y) |y| {
        for (0..self.grid_x) |x| {
            if (self.grid_buffer[pos] == player) {
                if (self.east(x, y, player, runlength)) {
                    return true;
                }
                if (self.south(x, y, player, runlength)) {
                    return true;
                }
                if (self.southeast(x, y, player, runlength)) {
                    return true;
                }
                if (self.southwest(x, y, player, runlength)) {
                    return true;
                }
            }
            pos += 1;
        }
    }
    return false;
}

fn east(self: *Self, x: usize, y: usize, player: u8, runlength: u8) bool {
    if (x + runlength > self.grid_x) {
        return false;
    }
    for (1..runlength) |i| {
        if (self.get(x + i, y) catch 0 != player) {
            return false;
        }
    }
    return true;
}

fn south(self: *Self, x: usize, y: usize, player: u8, runlength: u8) bool {
    if (y + runlength > self.grid_y) {
        return false;
    }
    for (1..runlength) |i| {
        if (self.get(x, y + i) catch 0 != player) {
            return false;
        }
    }
    return true;
}

fn southeast(self: *Self, x: usize, y: usize, player: u8, runlength: u8) bool {
    if (x + runlength > self.grid_x or y + runlength > self.grid_y) {
        return false;
    }
    for (1..runlength) |i| {
        if (self.get(x + i, y + i) catch 0 != player) {
            return false;
        }
    }
    return true;
}

fn southwest(self: *Self, x: usize, y: usize, player: u8, runlength: u8) bool {
    if (x < runlength or y + runlength > self.grid_y) {
        return false;
    }
    for (1..runlength) |i| {
        if (self.get(x -% i, y + i) catch 0 != player) {
            return false;
        }
    }
    return true;
}

pub fn is_full(self: *Self) bool {
    for (0..(self.grid_x * self.grid_y)) |i| {
        if (self.grid_buffer[i] == 0) {
            return false;
        }
    }
    return true;
}
