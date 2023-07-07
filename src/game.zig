const std = @import("std");
const httpz = @import("httpz");
const Grid = @import("grid.zig");
const Errors = @import("errors.zig");

const Self = @This();

const MAX_PLAYERS = 8;

const State = enum {
    init,
    login,
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
logged_in: [MAX_PLAYERS]bool = undefined,
clocks: [MAX_PLAYERS]i64 = undefined,
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
    for (0..MAX_PLAYERS) |i| {
        s.logged_in[i] = false;
    }
    return s;
}

/// signal() function transitions the game state to the new state, and signals the event handlers to update
fn signal(self: *Self, ev: Event) void {
    self.event_mutex.lock();
    defer self.event_mutex.unlock();
    self.last_event = ev;
    self.event_condition.broadcast();
    std.log.info("signal event {}", .{ev});
}

// clock() function returns a fragment with the current clock value
fn clock(self: *Self, stream: std.net.Stream) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    try stream.writeAll("event: clock\n");
    try stream.writer().print("data: {d}\n\n", .{std.time.timestamp() - self.start_time});
}

// header() GET req returns the title header, depending on the game state
pub fn header(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    std.log.info("GET /header {}", .{self.state});
    _ = req;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    switch (self.state) {
        .init => {
            res.body = "Setup New Game";
        },
        .login => {
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

/// app()  GET req returns the main app body, depending on the current state of the game, and the player
pub fn app(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const player = req.headers.get("x-player") orelse "";

    std.log.info("GET /app {} player {s}", .{ self.state, player });

    const w = res.writer();
    _ = w;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    switch (self.state) {
        .init => {
            res.body = @embedFile("html/setup_game.html");
        },
        .login => {
            // if this user is logged in, then show a list of who is logged in
            // if this user is not logged in, then show a login form
            return self.loginForm(req, res);
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

// loginForm() handler returns either a login form, or a display of who we are waiting for if the user is logged in
pub fn loginForm(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const w = res.writer();
    const player_value = req.headers.get("x-player") orelse "";
    const player = std.fmt.parseInt(u8, player_value, 10) catch 0;
    if (player > 0) {
        std.log.info("loginForm for player {}", .{player});
        res.body = "show who we are waiting on";
        return;
    }

    std.log.info("loginForm not logged in yet", .{});

    try w.print("<div>", .{});
    try w.print("<p>Select which player to play as:</p>", .{});
    try w.print("<ul>", .{});

    for (0..self.players) |i| {
        if (!self.logged_in[i]) {
            const p = i + 1;
            try w.print(
                \\ <li hx-post="/login/{}" hx-target="#player" onclick="setPlayer({})">Player {}</li>
            , .{ p, p, p });
        }
    }

    try w.print("</ul>", .{});
    try w.print("</div>", .{});
}

/// login() POST handler logs this player in, and returns the playerID
pub fn login(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    const player_value = req.param("player").?;
    const player = try std.fmt.parseInt(u8, player_value, 10);

    std.log.info("POST login {}", .{player});
    if (player < 1 or player > self.players) {
        res.status = 401;
        res.body = "Invalid Player";
        return;
    }
    if (self.logged_in[player - 1]) {
        res.status = 401;
        res.body = "That player is already logged in";
    }
    self.logged_in[player - 1] = true;
    self.clocks[player - 1] = std.time.timestamp();
    std.log.info("Player {} now logged in", .{player});
    try res.writer().print("{}", .{player});

    // if everyone is logged in, then proceed to the .running state, and signal .start
    // othervise, signal that a login happened, but we are still waiting for everyone to join
    var all_done = true;
    for (0..self.players) |i| {
        if (!self.logged_in[i]) {
            all_done = false;
            break;
        }
    }
    if (all_done) {
        self.state = .running;
        self.signal(.start);
    } else {
        self.signal(.login);
    }
}

/// setup() POST requ sets up a new game, with specified grid size and number of players
pub fn setup(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = res;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    const SetupRequest = struct {
        x: u8,
        y: u8,
        players: u8,
    };

    if (try req.json(SetupRequest)) |setup_request| {
        std.log.info("POST /setup {} {}", .{ self.state, setup_request });
        if (setup_request.x * setup_request.y > 144) {
            return Errors.GameError.GridTooBig;
        }
        if (setup_request.players > MAX_PLAYERS) {
            return Errors.GameError.TooManyPlayers;
        }
        self.grid_x = setup_request.x;
        self.grid_y = setup_request.y;
        self.players = setup_request.players;
        self.grid = try Grid.init(self.grid_x, self.grid_y);
        for (0..MAX_PLAYERS) |i| {
            self.logged_in[i] = false;
        }
        self.state = .login;
        self.signal(.wait); // transition to the wait for login state
    }
}

pub fn events(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    std.log.info("(event-source) GET /events {}", .{self.state});
    _ = req;
    const clock_interval = std.time.ns_per_s * 30;

    var stream = try res.startEventStream();

    // on initial connect, send the clock details, and send the last event processed
    try self.clock(stream);
    try stream.writer().print("event: update\ndata: {s}\n\n", .{@tagName(self.last_event)});

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
            std.log.info("condition fired here ? last event is {}", .{self.last_event});
            self.game_mutex.lock();
            defer self.game_mutex.unlock();
            try stream.writer().print("event: update\ndata: {s}\n\n", .{@tagName(self.last_event)});
        }
    }
}
