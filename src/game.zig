const std = @import("std");
const httpz = @import("httpz");
const Board = @import("board.zig");
const Errors = @import("errors.zig");

const start_countdown_timer: i64 = 30;
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
    stalemate,
};

const PlayerMode = enum {
    normal,
    flipper,
    nuke,
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
flipper_chance: u8 = 0,
nuke_chance: u8 = 0,
player_mode: PlayerMode = .normal,
board: Board = undefined,
logged_in: [MAX_PLAYERS]bool = undefined,
state: State = .init,
last_event: Event = .none,
expiry_time: i64 = undefined,
current_player: u8 = 0,
prng: std.rand.Xoshiro256 = undefined,
watcher: std.Thread = undefined,
countdown_timer: i64 = start_countdown_timer,

/// init returns a new Game object
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
        .flipper_chance = flipper,
        .prng = std.rand.DefaultPrng.init(os_seed),
        .countdown_timer = start_countdown_timer,
    };
    for (0..MAX_PLAYERS) |i| {
        s.logged_in[i] = false;
    }
    return s;
}

/// startWatcher starts a thread to watch a given game
pub fn startWatcher(self: *Self) !void {
    self.watcher = try std.Thread.spawn(.{}, Self.watcherThread, .{self});
    self.watcher.detach();
}

/// watcherThread loops forever, updating the state based upon expiring clocks
fn watcherThread(self: *Self) void {
    while (true) {
        self.game_mutex.lock();
        var expiry_time = self.expiry_time;
        const state = self.state;
        self.game_mutex.unlock();

        if (state != .init) {
        std.log.info("is {} > {}", .{std.time.timestamp(), expiry_time});
            if (std.time.timestamp() > expiry_time) {
                std.log.debug("Waited too long", .{});
                if (state == .winner) {
                    self.reboot();
                    return;
                }

                self.game_mutex.lock();
                self.current_player = 100;
                self.state = .winner;
                self.signal(.victory);
                self.game_mutex.unlock();
            }
        }
        std.time.sleep(std.time.ns_per_s);
    }
}

/// randPlayerMode will return a newly generated mode base of the % chance of things in the current game settings.
/// use this to get a random mode for the next player's turn at the end of the turn.
fn randPlayerMode(self: *Self) PlayerMode {
    const dice = (self.prng.random().int(u8) % (11)) * 10;
    if (dice < self.flipper_chance) {
        return .flipper;
    }
    if (dice < self.nuke_chance) {
        return .nuke;
    }
    return .normal;
}

/// addRoutes sets up the routes and handlers used in this game object
pub fn addRoutes(self: *Self, router: anytype) void {
    _ = self;
    router.get("/events", Self.events); // SSE event stream of game state changes
    router.get("/app", Self.app); // Get the app contents, which depends on the current user + game state
    router.get("/header", Self.header); // Get the header fragment that describes the game state
    router.post("/setup", Self.setup); // Process the setup for a new game
    router.post("/login/:player", Self.login); // login !
    router.post("/square/:x/:y", Self.square); // player clicks on a square
    router.post("/restart", Self.restart);
    router.get("/images/zero-wing.jpg", Self.zeroWing);
}

/// signal() function transitions the game state to the new state, and signals the event handlers to update
// you must have the game_mutex locked already when you call signal()
fn signal(self: *Self, ev: Event) void {
    // locks the event_mutex (not the game_mutex) - so that it can broadcast all event threads
    self.event_mutex.lock();
    self.last_event = ev;
    self.expiry_time = std.time.timestamp() + self.countdown_timer;
    self.event_condition.broadcast();
    self.event_mutex.unlock();

    std.log.info("signal event {}", .{ev});
}

/// reboot will reboot the server back to the vanilla state. Call this when everything has timed out, and we want to go right back to the original start
fn reboot(self: *Self) void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    self.state = .init;
    self.grid_x = 3;
    self.grid_y = 3;
    self.players = 2;
    self.needed_to_win = 3;
    self.flipper_chance = 0;
    self.expiry_time = std.time.timestamp() + 100;
    self.signal(.init);
}

/// restart will set the game back to the setup phase, using the current Game parameters
fn restart(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    res.body = "restarted";
    self.state = .init;
    self.countdown_timer = start_countdown_timer;
    self.expiry_time = std.time.timestamp() + 100;
    self.signal(.init);
}

/// clock() function emits an event of type clock with the current number of remaining seconds until the next expiry time
fn clock(self: *Self, stream: std.net.Stream) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    const w = stream.writer();
    try w.writeAll("event: clock\n");
    var remaining = self.expiry_time - std.time.timestamp();
    if (self.state == .running and remaining > 0) {
        try stream.writer().print("data: {d} seconds remaining ...\n\n", .{self.expiry_time - std.time.timestamp()});
    } else {
        try w.writeAll("data: 🕑\n\n");
    }
}

/// getPlayer is a utility function to extract the player ID from the request header
fn getPlayer(self: *Self, req: *httpz.Request) u8 {
    _ = self;
    return std.fmt.parseInt(u8, req.headers.get("x-player") orelse "", 10) catch @as(u8, 0);
}

/// zeroWing handler to get the background image
fn zeroWing(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = self;
    _ = req;
    res.body = @embedFile("images/zero-wing-gradient.jpg");
}

/// header() GET req returns the title header, depending on the game state
fn header(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    const player = self.getPlayer(req);
    std.log.info("GET /header {} player {}", .{ self.state, player });

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
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    const player = self.getPlayer(req);
    std.log.info("GET /app {} player {}", .{ self.state, player });

    switch (self.state) {
        .init => {
            const w = res.writer();
            try w.print(@embedFile("html/setup/setup_game.x.html"), .{
                .x = self.grid_x,
                .y = self.grid_y,
                .players = self.players,
                .win = self.needed_to_win,
                .flipper = self.flipper_chance,
                .nuke = self.nuke_chance,
            });
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

/// calcBoardClass is used to get the CSS class for the board, based on whether it's this players turn, and what mode they are in
fn calcBoardClass(self: *Self, player: u8) []const u8 {
    if (player == self.current_player) {
        return switch (self.player_mode) {
            .normal => "active-player",
            .flipper => "active-player-flip",
            .nuke => "active-player-nuke",
        };
    }
    return "inactive-player";
}

/// showBoard writes the current board to the HTTP response, based on the current player and what state they are in
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
                if (self.player_mode == .flipper and self.state == .running and player == self.current_player) {
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

    if (self.current_player == player) {
        switch (self.player_mode) {
            .normal => try w.writeAll(@embedFile("html/board/your-move.html")),
            .flipper => try w.writeAll(@embedFile("html/board/zero-wing-enabled.html")),
            .nuke => try w.writeAll(@embedFile("html/board/setup-us-the-bomb.html")),
        }
    }

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
        self.expiry_time = std.time.timestamp() + start_countdown_timer;
        self.countdown_timer = start_countdown_timer;
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
    if (self.player_mode == .nuke) {
        try self.board.nuke(x - 1, y - 1);
    }
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

    // end of turn
    self.player_mode = self.randPlayerMode();
    if (self.countdown_timer > 1) {
        self.countdown_timer -= 1;
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
        flipper: u8,
        nuke: u8,
    };

    // sanity check the inputs !
    if (try req.json(SetupRequest)) |setup_request| {
        std.log.info("POST /setup {} {}", .{ self.state, setup_request });
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
        self.flipper_chance = setup_request.flipper;
        self.nuke_chance = setup_request.nuke;

        self.player_mode = self.randPlayerMode();

        self.board = try Board.init(self.grid_x, self.grid_y);
        for (0..MAX_PLAYERS) |i| {
            self.logged_in[i] = false;
        }
        self.state = .login;
        self.signal(.wait); // transition to the wait for login state
    }
}

/// events GET handler is an SSE stream that emits events whenever the state changes
/// or a clock event expires. Uses the Game.event_condition to synch with the outer threads
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
        var next_clock: u64 = switch (self.state) {
            .running, .winner, .stalemate => 1,
            .login => 30,
            .init => 60,
        };

        self.event_condition.timedWait(&self.event_mutex, std.time.ns_per_s * next_clock) catch |err| {
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
            self.game_mutex.lock();
            defer self.game_mutex.unlock();
            std.log.debug("condition fired - last event is {}", .{self.last_event});
            try stream.writer().print("event: update\ndata: {s}\n\n", .{@tagName(self.last_event)});
        }
    }
}
