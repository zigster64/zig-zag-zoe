const std = @import("std");
const httpz = @import("httpz");
const Grid = @import("grid.zig");
const Errors = @import("errors.zig");

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
logged_in: [8]bool = undefined,
clocks: [8]i64 = undefined,

start_time: i64 = undefined,

pub fn init(grid_x: u8, grid_y: u8, players: u8) !Self {
    if (players > 8) {
        return Errors.GameError.TooManyPlayers;
    }

    var s = Self{
        .grid = try Grid.init(grid_x, grid_y),
        .grid_x = grid_x,
        .grid_y = grid_y,
        .players = players,
        .start_time = std.time.timestamp(),
    };
    for (0..8) |i| {
        s.logged_in[i] = false;
    }
    return s;
}

fn clock(self: *Self, stream: std.net.Stream) !void {
    try stream.writeAll("event: clock\n");
    try stream.writer().print("data: {d}\n\n", .{std.time.timestamp() - self.start_time});
}

pub fn eventLoop(self: *Self, _req: *httpz.Request, res: *httpz.Response) !void {
    _ = _req;
    const clock_interval = std.time.ns_per_s * 1;

    var stream = try res.startEventStream();

    // on initial connect, send the clock details
    try self.clock(stream);

    // aquire a lock on the event_mutex
    self.event_mutex.lock();
    defer self.event_mutex.unlock();

    while (true) {
        self.event_condition.timedWait(&self.event_mutex, clock_interval) catch |err| {
            if (err == error.Timeout) {
                try self.clock(stream);
                continue;
            }
            // some other error - abort !
            std.debug.print("got an error waiting on the condition {any}!\n", .{err});
            return err;
        };

        // if we get here, it means that the event_condition was signalled, so we can send the updated document now
    }
}
