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
board: Board = undefined,
logged_in: [MAX_PLAYERS]bool = undefined,
clocks: [MAX_PLAYERS]i64 = undefined,
state: State = .init,
last_event: Event = .none,
start_time: i64 = undefined,
current_player: u8 = 0,

pub fn init(grid_x: u8, grid_y: u8, players: u8, needed_to_win: u8) !Self {
    if (players > 8) {
        return Errors.GameError.TooManyPlayers;
    }

    var s = Self{
        .board = try Board.init(grid_x, grid_y),
        .grid_x = grid_x,
        .grid_y = grid_y,
        .players = players,
        .needed_to_win = needed_to_win,
        .start_time = std.time.timestamp(),
    };
    for (0..MAX_PLAYERS) |i| {
        s.logged_in[i] = false;
    }
    return s;
}

pub fn addRoutes(self: *Self, router: anytype) void {
    _ = self;
    router.get("/events", Self.events); // SSE event stream of game state changes
    router.get("/app", Self.app); // Get the app contents, which depends on the current user + game state
    router.get("/header", Self.header); // Get the header fragment that describes the game state
    router.post("/setup", Self.setup); // Process the setup for a new game
    router.post("/login/:player", Self.login); // login !
    router.post("/square/:x/:y", Self.square); // player clicks on a square
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
fn header(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const player_value = req.headers.get("x-player") orelse "";
    const player = std.fmt.parseInt(u8, player_value, 10) catch 0;
    std.log.info("GET /header {} player {}", .{ self.state, player });
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
            const w = res.writer();
            try w.print(
                \\ <div>Player {}'s turn</div>
                \\ <div>Clock:
                \\ <span class="clock" hx-ext="sse" sse-connect="/events" sse-swap="clock">
                \\ .. time goes in here ..
                \\ </span>
                \\ Seconds
                \\ </div>
            , .{self.current_player});
        },
        .winner => {
            if (player == self.current_player) {
                res.body = "Victory !";
            } else {
                res.body = "Game Over, You LOST !";
            }
        },
        .stalemate => {
            res.body = "Game over, nobody can win from here";
        },
    }
}

/// app()  GET req returns the main app body, depending on the current state of the game, and the player
fn app(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const player_value = req.headers.get("x-player") orelse "";
    const player = std.fmt.parseInt(u8, player_value, 10) catch 0;

    std.log.info("GET /app {} player {s}", .{ self.state, player_value });

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
            try w.writeAll(
                \\ <input type=submit hx-post="/restart">Restart with New Game</input>
            );
        },
        .stalemate => {
            res.body = "The board is blocked, and nobody can win from here";
        },
    }
}

fn showBoard(self: *Self, player: u8, res: *httpz.Response) !void {
    const w = res.writer();

    if (player == self.current_player) {
        try w.print(
            \\ <div onload="setGridColumns({})" class="grid-container-active">
        , .{self.grid_y});
    } else {
        try w.print(
            \\ <div onload="setGridColumns({})" class="grid-container">
        , .{self.grid_y});
    }

    for (0..self.grid_y) |y| {
        for (0..self.grid_x) |x| {
            const value = try self.board.get(x, y);

            // used square that we cant click on
            if (value != 0) {
                try w.print(
                    \\ <div class="grid-used-square">
                    \\ {}
                    \\ </div>
                , .{try self.board.get(x, y)});
                continue;
            }

            // we are the active player, and the square is not used yet
            if (self.state == .running and player == self.current_player) {
                try w.print(
                    \\ <div class="grid-empty-square-clickable" hx-post="/square/{}/{}"
                , .{ x + 1, y + 1 });
                try w.writeAll(
                    \\ hx-headers='js:{"x-player": getPlayer()}'>
                    \\ ?
                    \\ </div>
                );
                continue;
            }

            // empty square that we cant click on,because its another player's turn
            try w.print(
                \\ <div class="grid-empty-square">
                \\ ?
                \\ </div> 
            , .{});
        }
    }

    try w.writeAll(
        \\ </div>
    );

    return;
}

// loginForm() handler returns either a login form, or a display of who we are waiting for if the user is logged in
fn loginForm(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const w = res.writer();
    const player_value = req.headers.get("x-player") orelse "";
    const player = std.fmt.parseInt(u8, player_value, 10) catch 0;
    if (player > 0) {
        try w.writeAll("Waiting for players :<ul>");
        for (0..self.players) |p| {
            if (!self.logged_in[p]) {
                try w.print("<li>Player {}</li>", .{p + 1});
            }
        }
        try w.writeAll("</ul>");
        return;
    }

    std.log.debug("loginForm not logged in yet", .{});

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

    const player_value = req.headers.get("x-player") orelse "";
    const player = std.fmt.parseInt(u8, player_value, 10) catch 0;

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
    try self.board.put(x - 1, y - 1, player);

    if (self.board.victory(self.current_player, self.needed_to_win)) {
        // std.log.info("Victory for player {}", .{self.current_player});
        res.body = "Victory";
        self.signal(.victory);
        self.state = .winner;
        return;
    }

    if (self.board.is_full()) {
        // std.log.info("Board is full - stalemate !", .{});
        res.body = "Stalemate";
        self.signal(.stalemate);
        return;
    }

    self.current_player += 1;
    if (self.current_player > self.players) {
        self.current_player = 1;
    }
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
        if (setup_request.x < 2 or setup_request.x > 12) {
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
