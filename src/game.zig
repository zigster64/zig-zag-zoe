const std = @import("std");
const httpz = @import("httpz");
const Board = @import("board.zig");
const Errors = @import("errors.zig");

const Self = @This();

const MAX_PLAYERS = 8;

const State = enum {
    init,
    login,
    running,
    winner,
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
    failure,
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
needed_to_win: u8 = 3,
flipper: u8 = 0,
can_flip: bool = false,
board: Board = undefined,
logged_in: [MAX_PLAYERS]bool = undefined,
clocks: [MAX_PLAYERS]i64 = undefined,
state: State = .init,
last_event: Event = .none,
start_time: i64 = undefined,
current_player: u8 = 0,
prng: std.rand.Xoshiro256 = undefined,

pub fn init(grid_x: u8, grid_y: u8, players: u8, needed_to_win: u8, flipper: u8) !Self {
    if (players > 8) {
        return Errors.GameError.TooManyPlayers;
    }

    // seed the RNG
    var os_seed: u64 = undefined;
    try std.os.getrandom(std.mem.asBytes(&os_seed));

    var s = Self{
        .board = try Board.init(grid_x, grid_y),
        .grid_x = grid_x,
        .grid_y = grid_y,
        .players = players,
        .needed_to_win = needed_to_win,
        .flipper = flipper,
        .start_time = std.time.timestamp(),
        .prng = std.rand.DefaultPrng.init(os_seed),
    };
    for (0..MAX_PLAYERS) |i| {
        s.logged_in[i] = false;
    }
    return s;
}

fn newCanFlip(self: *Self) bool {
    const x = self.prng.random().int(u8) % (11);
    return x > self.flipper;
}

pub fn addRoutes(self: *Self, router: anytype) void {
    _ = self;
    router.get("/events", Self.events); // SSE event stream of game state changes
    router.get("/app", Self.app); // Get the app contents, which depends on the current user + game state
    router.get("/header", Self.header); // Get the header fragment that describes the game state
    router.post("/setup", Self.setup); // Process the setup for a new game
    router.post("/login/:player", Self.login); // login !
    router.post("/square/:x/:y", Self.square); // player clicks on a square
    router.post("/restart", Self.restart);
}

/// signal() function transitions the game state to the new state, and signals the event handlers to update
fn signal(self: *Self, ev: Event) void {
    self.event_mutex.lock();
    defer self.event_mutex.unlock();
    self.last_event = ev;
    self.event_condition.broadcast();
    std.log.info("signal event {}", .{ev});
}

fn restart(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    res.body = "restarted";
    self.state = .init;
    self.signal(.init);
}

// clock() function returns a fragment with the current clock value
fn clock(self: *Self, stream: std.net.Stream) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    try stream.writeAll("event: clock\n");
    try stream.writer().print("data: {d}\n\n", .{std.time.timestamp() - self.start_time});
}

/// getPlayer is a utility function to extract the player ID from the request header
fn getPlayer(self: *Self, req: *httpz.Request) u8 {
    _ = self;
    return std.fmt.parseInt(u8, req.headers.get("x-player") orelse "", 10) catch @as(u8, 0);
}

// header() GET req returns the title header, depending on the game state
fn header(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const player = self.getPlayer(req);
    std.log.info("GET /header {} player {}", .{ self.state, player });
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    switch (self.state) {
        .init => {
            res.body = @embedFile("html/header/init.html");
        },
        .login => {
            res.body = @embedFile("html/header/login.html");
        },
        .running => {
            const w = res.writer();
            try w.print(@embedFile("html/header/running.x.html"), .{
                .current_player = self.current_player,
            });
        },
        .winner => {
            if (player == self.current_player) {
                res.body = @embedFile("html/header/winner-victory.html");
            } else {
                res.body = @embedFile("html/header/winner-lost.html");
            }
        },
        .stalemate => {
            res.body = @embedFile("html/header/stalemate.html");
        },
    }
}

/// app()  GET req returns the main app body, depending on the current state of the game, and the player
fn app(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const player = self.getPlayer(req);
    std.log.info("GET /app {} player {}", .{ self.state, player });

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
            return self.showBoard(player, res);
        },
        .winner => {
            try self.showBoard(0, res);
            const w = res.writer();
            try w.writeAll(@embedFile("html/widgets/restart-button.html"));
        },
        .stalemate => {
            res.body = @embedFile("html/stalemate.html");
        },
    }
}

fn calcBoardClass(self: *Self, player: u8) []const u8 {
    if (player == self.current_player) {
        if (self.can_flip) {
            return "active-player-flip";
        }
        return "active-player";
    }
    return "inactive-player";
}

fn showBoard(self: *Self, player: u8, res: *httpz.Response) !void {
    const w = res.writer();
    try w.print(@embedFile("html/board/start-grid.x.html"), .{
        .class = self.calcBoardClass(player),
        .columns = self.grid_x,
    });

    for (0..self.grid_y) |y| {
        for (0..self.grid_x) |x| {
            const value = try self.board.get(x, y);

            // used square that we cant normally click on
            if (value != 0) {
                if (self.can_flip and self.state == .running and player == self.current_player) {
                    // BUT ! we have flipper powers this turn, so we can change another player's piece to our piece !
                    try w.print(@embedFile("html/board/clickable-square.x.html"), .{
                        .class = "grid-square-clickable",
                        .x = x + 1,
                        .y = y + 1,
                        .player = value,
                    });
                    continue;
                }

                try w.print(@embedFile("html/board/square.x.html"), .{
                    .class = "grid-square",
                    .player = value,
                });
                continue;
            }

            // we are the active player, and the square is not used yet
            if (self.state == .running and player == self.current_player) {
                try w.print(@embedFile("html/board/clickable-square.x.html"), .{
                    .class = "grid-square-clickable",
                    .x = x + 1,
                    .y = y + 1,
                    .player = value,
                });
                continue;
            }

            // empty square that we cant click on,because its another player's turn
            try w.print(@embedFile("html/board/square.x.html"), .{
                .class = "grid-square",
                .player = value,
            });
        }
    }

    try w.writeAll(@embedFile("html/board/end-grid.html"));

    return;
}

// loginForm() handler returns either a login form, or a display of who we are waiting for if the user is logged in
fn loginForm(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const w = res.writer();
    const player = self.getPlayer(req);

    if (player > 0) {
        try w.writeAll(@embedFile("html/login/waiting-title.html"));
        for (0..self.players) |p| {
            if (!self.logged_in[p]) {
                try w.print(@embedFile("html/login/waiting-player.x.html"), .{
                    .player = p + 1,
                });
            }
        }
        try w.writeAll(@embedFile("html/login/waiting-end.html"));
        return;
    }

    try w.writeAll(@embedFile("html/login/login-form-start.html"));

    for (0..self.players) |i| {
        if (!self.logged_in[i]) {
            try w.print(@embedFile("html/login/login-form-select-player.x.html"), .{
                .player = i + 1,
            });
        }
    }

    try w.writeAll(@embedFile("html/login/login-form-end.html"));
}

/// login() POST handler logs this player in, and returns the playerID
fn login(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
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
    var all_logged_in = true;
    for (0..self.players) |i| {
        if (!self.logged_in[i]) {
            all_logged_in = false;
            break;
        }
    }
    if (all_logged_in) {
        self.state = .running;
        self.current_player = 1;
        self.start_time = std.time.timestamp();
        self.signal(.start);
    } else {
        self.signal(.login);
    }
}

// square POST handler - user has clicked on a square to place their peice and end their turn
fn square(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    const x = std.fmt.parseInt(usize, req.param("x").?, 10) catch 0;
    const y = std.fmt.parseInt(usize, req.param("y").?, 10) catch 0;

    const player = self.getPlayer(req);

    // std.log.info("POST square {},{} for player {}", .{ x, y, player });
    if (player < 1 or player > self.players) {
        res.status = 401;
        res.body = "Invalid Player";
        return;
    }
    if (x < 1 or x > self.grid_x) {
        res.status = 400;
        res.body = "Invalid X Value";
        return;
    }
    if (y < 1 or y > self.grid_y) {
        res.status = 400;
        res.body = "Invalid Y Value";
        return;
    }
    std.log.debug("board.put {},{} = {}", .{ x, y, player });
    try self.board.put(x - 1, y - 1, player);

    if (self.board.victory(self.current_player, self.needed_to_win)) {
        std.log.info("Victory for player {}", .{self.current_player});
        res.body = "Victory";
        self.signal(.victory);
        self.state = .winner;
        return;
    }

    if (self.board.is_full()) {
        std.log.info("Board is full - stalemate !", .{});
        res.body = "Stalemate";
        self.signal(.stalemate);
        self.state = .stalemate;
        return;
    }

    self.current_player += 1;
    if (self.current_player > self.players) {
        self.current_player = 1;
    }

    self.can_flip = self.newCanFlip();
    self.signal(.next);
}

/// setup() POST requ sets up a new game, with specified grid size and number of players
fn setup(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = res;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();
    const SetupRequest = struct {
        x: u8,
        y: u8,
        players: u8,
        win: u8,
        flipper: u8,
    };

    // sanity check the inputs !
    if (try req.json(SetupRequest)) |setup_request| {
        // std.log.info("POST /setup {} {}", .{ self.state, setup_request });
        if (setup_request.x * setup_request.y > 144) {
            return Errors.GameError.GridTooBig;
        }
        if (setup_request.players > MAX_PLAYERS) {
            return Errors.GameError.TooManyPlayers;
        }
        if (setup_request.x < 2 or setup_request.x > 15) {
            return Errors.GameError.InvalidSetup;
        }
        if (setup_request.y < 2 or setup_request.y > 12) {
            return Errors.GameError.InvalidSetup;
        }
        if (setup_request.win > setup_request.y) {
            return Errors.GameError.InvalidSetup;
        }
        self.grid_x = setup_request.x;
        self.grid_y = setup_request.y;
        self.players = setup_request.players;
        self.needed_to_win = setup_request.win;
        self.flipper = setup_request.flipper;

        self.can_flip = self.newCanFlip();

        self.board = try Board.init(self.grid_x, self.grid_y);
        for (0..MAX_PLAYERS) |i| {
            self.logged_in[i] = false;
        }
        self.state = .login;
        self.signal(.wait); // transition to the wait for login state
    }
}

fn events(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    std.log.info("(event-source) GET /events {}", .{self.state});
    _ = req;

    var stream = try res.startEventStream();

    // on initial connect, send the clock details, and send the last event processed
    try self.clock(stream);
    try stream.writer().print("event: update\ndata: {s}\n\n", .{@tagName(self.last_event)});

    // aquire a lock on the event_mutex
    self.event_mutex.lock();
    defer self.event_mutex.unlock();

    while (true) {
        // work out how long until the clock gets to the next 10s mark
        const seconds_since_last_tenner: u64 = @intCast(@mod(std.time.timestamp() - self.start_time, 10));
        const next_clock = std.time.ns_per_s * (10 -| seconds_since_last_tenner);

        self.event_condition.timedWait(&self.event_mutex, next_clock) catch |err| {
            if (err == error.Timeout) {
                try self.clock(stream);
                continue;
            }
            // some other error - abort !
            std.log.debug("got an error waiting on the condition {any}", .{err});
            return err;
        };

        // if we get here, it means that the event_condition was signalled
        // so we check the current event state of the Game, and emit an SSE event to output the
        // current state to the client
        {
            std.log.debug("condition fired - last event is {}", .{self.last_event});
            self.game_mutex.lock();
            defer self.game_mutex.unlock();
            try stream.writer().print("event: update\ndata: {s}\n\n", .{@tagName(self.last_event)});
        }
    }
}
