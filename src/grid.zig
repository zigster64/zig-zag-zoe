const std = @import("std");
const Errors = @import("errors.zig");

const Self = @This();

// Game thread control
game_mutex: std.Thread.Mutex = .{},
event_mutex: std.Thread.Mutex = .{},
event_condition: std.Thread.Condition = .{},

// Game state variables
grid_x: u8 = 1,
grid_y: u8 = 1,
grid_buffer: [144]u8 = undefined,

pub fn init(grid_x: u8, grid_y: u8) Errors.GameError!Self {
    if (grid_x * grid_y > 144) {
        return Errors.GameError.GridTooBig;
    }

    return Self{
        .grid_x = grid_x,
        .grid_y = grid_y,
    };
}

// Handlers
// - EVENT GET game  (event: clock, event: next, event: victory, event: stalemate, event: restart, event: wait, event: login)

// Init the game:
// - GET / ... boot the game up, return a form to define the params
// - POST new_game (x, y, num_players)   -> IF everyone is logged in, then event: next, else event: wait

// Waiting for everyone to connect
// - GET / .. if not logged in, present login form, otherwise show who is logged in and who is waiting
// - POST login (player_id) -> event: login

// Now when all players are in, loop through :
// - GET / ... when the game is running, returns the game map setup for each player
// - PUT piece (player_id, x, y)  -> event: [next, victory, stalemate]

// Game has ended
// - GET / .. show the game board, and show who won, or whether it was a stalemate
// - POST restart  -> event: restart
