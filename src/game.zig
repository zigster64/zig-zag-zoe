const std = @import("std");
const httpz = @import("httpz");
const Grid = @import("grid.zig");

const Self = @This();

// Game thread control
game_mutex: std.Thread.Mutex = .{},
event_mutex: std.Thread.Mutex = .{},
event_condition: std.Thread.Condition = .{},

// Game state variables
grid_x: u8 = 1,
grid_y: u8 = 1,
players: u8 = 2,
grid: Grid = undefined,
logged_in: []bool = undefined,

pub fn init(grid_x: u8, grid_y: u8, players: u8) !Self {
    return Self{
        .grid = try Grid.init(grid_x, grid_y),
        .grid_x = grid_x,
        .grid_y = grid_y,
        .players = players,
    };
}

// Add handlers for :
// - GET
// - POST login (player_id)
// - PUT piece (player_id, x, y)
// - GET event clock
// - GET event next_move
// - POST new_game
