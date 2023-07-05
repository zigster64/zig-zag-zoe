const std = @import("std");
const httpz = @import("httpz");
const Grid = @import("grid.zig");
const Errors = @import("errors.zig");

const Self = @This();

const State = enum {
    init,
    logins,
    running,
    victory,
    stalemate,
};

const Event = enum {
    none,
    init,
    wait,
    login,
    start,
    next,
    victory,
    stalemate,
};

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
state: State = .init,
last_event: Event = .none,

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
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    try stream.writeAll("event: clock\n");
    try stream.writer().print("data: {d}\n\n", .{std.time.timestamp() - self.start_time});
}

pub fn header(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    std.log.info("GET /header {}", .{self.state});
    _ = req;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    switch (self.state) {
        .init => {
            res.body = "Setup New Game";
        },
        .logins => {
            res.body = "Waiting for Logins";
        },
        .running => {
            res.body = @embedFile("html/clock.html");
        },
        .victory => {
            res.body = @embedFile("html/victory.html");
        },
        .stalemate => {
            res.body = @embedFile("html/stalemate.html");
        },
    }
}

pub fn app(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    std.log.info("GET /app {}", .{self.state});

    const w = res.writer();
    _ = w;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    switch (self.state) {
        .init => {
            res.body = @embedFile("html/setup_game.html");
        },
        .logins => {
            // if this user is logged in, then show a list of who is logged in
            // if this user is not logged in, then show a login form
            res.body = "login details";
        },
        .running => {
            res.body = "show the grid, with controls depending on who's turn it is";
        },
        .victory => {
            res.body = "show the grid and highlight the winning move";
        },
        .stalemate => {
            res.body = "show the grid stalemate animation";
        },
    }
}

pub fn setup(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    std.log.info("POST /setup {}", .{self.state});
    _ = res;
    const SetupRequest = struct {
        x: u8,
        y: u8,
        players: u8,
    };
    if (try req.json(SetupRequest)) |setup_request| {
        std.log.info("setup request {}\n", .{setup_request});
    }
}

pub fn events(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    std.log.info("(event-source) GET /events {}", .{self.state});
    _ = req;
    const clock_interval = std.time.ns_per_s * 5;

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

        // if we get here, it means that the event_condition was signalled
        // so we check the current event state of the Game, and emit an SSE event to output the
        // current state to the client
        {
            self.game_mutex.lock();
            defer self.game_mutex.unlock();
            try stream.writer().print("event: update\ndata: {s}\n\n", .{@tagName(self.last_event)});
        }
    }
}
