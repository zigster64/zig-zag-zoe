const std = @import("std");
const httpz = @import("httpz");
const zts = @import("zts");
const Board = @import("board.zig");
const Errors = @import("errors.zig");
const uuid = @import("uuid.zig");

const start_countdown_timer: i64 = 30;
const initial_countdown_timer: i64 = 120;
const all_players: u8 = 100;

const Self = @This();

pub const MAX_PLAYERS = 8;

const State = enum {
    init, // waiting for someone to set us up the game
    login, // waiting for everyone to login
    running, // game is running
    winner, // we have a winner
    stalemate, // board is full and no winner
};

const Event = enum {
    none, // null event
    init, // back to the start screen
    wait, // someone set us up the game, start waiting for logins
    login, // someone logged in, and we are still waiting for other players to login
    start, // everyone is logged in, and the game has started
    next, // someone finished their turn, and its now the next players turn
    victory, // someone won the game, and all base are belong to them
    stalemate, // someone placed a piece and now all is lost because the board is full and nobody won
};

const PlayerMode = enum {
    normal, // place piece on empty square
    zeroWing, // place piece anywhere, including other player's squares
    nuke, // place piece on empty square, and annihilate adjacent squares
};

// Game thread control
game_mutex: std.Thread.Mutex = .{},
event_mutex: std.Thread.Mutex = .{},
event_condition: std.Thread.Condition = .{},

// Game state variables
grid_x: u8 = 1,
grid_y: u8 = 1,
number_of_players: u8 = 2,
needed_to_win: u8 = 3,
zero_wing_chance: u8 = 0,
nuke_chance: u8 = 0,
player_mode: PlayerMode = .normal,
board: Board = undefined,
logged_in: [MAX_PLAYERS]uuid.UUID = undefined,
state: State = .init,
last_event: Event = .none,
expiry_time: i64 = undefined,
current_player: u8 = 0,
prng: std.rand.Xoshiro256 = undefined,
watcher: std.Thread = undefined,
countdown_timer: i64 = start_countdown_timer,
last_rss: isize = 0,

/// init returns a new Game object
pub fn init(grid_x: u8, grid_y: u8, players: u8, needed_to_win: u8, zero_wing: u8) !Self {
    if (players > MAX_PLAYERS) {
        return Errors.GameError.TooManyPlayers;
    }

    // seed the RNG
    var os_seed: u64 = undefined;
    try std.os.getrandom(std.mem.asBytes(&os_seed));

    var s = Self{
        .board = try Board.init(grid_x, grid_y),
        .grid_x = grid_x,
        .grid_y = grid_y,
        .number_of_players = players,
        .needed_to_win = needed_to_win,
        .zero_wing_chance = zero_wing,
        .prng = std.rand.DefaultPrng.init(os_seed),
        .countdown_timer = start_countdown_timer,
    };
    s.zapLogins();
    return s;
}

/// zayLogins clears the logins array
fn zapLogins(self: *Self) void {
    for (0..MAX_PLAYERS) |i| {
        self.logged_in[i] = uuid.zero;
    }
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
        const expiry_time = self.expiry_time;
        const state = self.state;
        self.game_mutex.unlock();
        const t = std.time.timestamp();

        if (state != .init) {
            if (t > expiry_time) {
                std.log.debug("Waited too long", .{});
                if (state == .winner) {
                    self.reboot();
                    continue;
                }

                self.game_mutex.lock();
                self.current_player = all_players;
                self.expiry_time = t + start_countdown_timer;
                self.newState(.winner, .victory);
                self.game_mutex.unlock();
            }
        }
        std.time.sleep(std.time.ns_per_s);
    }
}

/// rollDice function returns true/false if some roll of a D100 <= the % percent chance given
fn rollDice(self: *Self, percent: usize) bool {
    return (self.prng.random().intRangeAtMost(usize, 1, 100) <= percent);
}

/// randPlayerMode will return a newly generated mode base of the % chance of things in the current game settings.
/// use this to get a random mode for the next player's turn at the end of the turn.
fn randPlayerMode(self: *Self) PlayerMode {
    // roll a dice for the zero wing
    if (self.rollDice(self.zero_wing_chance)) {
        return .zeroWing;
    }

    // roll a new dice for the bomb
    if (self.rollDice(self.nuke_chance)) {
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

    router.get("/audio/your-turn.mp3", Self.yourTurnAudio);
    router.get("/audio/zero-wing.mp3", Self.zeroWingAudio);
    router.get("/audio/nuke.mp3", Self.nukeAudio);
    router.get("/audio/victory.mp3", Self.victoryAudio);
    router.get("/audio/lost.mp3", Self.lostAudio);
}

pub fn logExtra(self: *Self, req: *httpz.Request, extra: []const u8) void {
    // do some memory logging and stats here
    self.game_mutex.lock();
    const player = self.getPlayer(req);
    const ru = std.os.getrusage(0);
    std.log.info("[{}:{s}:{}:{}:{}] {s} {s} {s}", .{ std.time.timestamp(), @tagName(self.state), player, ru.maxrss, ru.maxrss - self.last_rss, @tagName(req.method), req.url.raw, extra });
    self.last_rss = ru.maxrss;
    self.game_mutex.unlock();
}

pub fn log(self: *Self, req: *httpz.Request, elapsedUs: i128) void {
    // do some memory logging and stats here
    self.game_mutex.lock();
    const player = self.getPlayer(req);
    const ru = std.os.getrusage(0);
    std.log.info("[{}:{s}:{}:{}:{}] {s} {s} ({}µs)", .{ std.time.timestamp(), @tagName(self.state), player, ru.maxrss, ru.maxrss - self.last_rss, @tagName(req.method), req.url.raw, elapsedUs });
    self.game_mutex.unlock();
    self.last_rss = ru.maxrss;
}

pub fn logger(self: *Self, action: httpz.Action(*Self), req: *httpz.Request, res: *httpz.Response) !void {
    // comment this debug out if you want to log the entry to each function - maybe for debugging some handle that hangs
    // std.log.debug("[{}:{s}] {s} {s} START ..", .{ std.time.timestamp(), @tagName(self.state), @tagName(req.method), req.url.raw });
    const t1 = std.time.microTimestamp();
    defer self.log(req, std.time.microTimestamp() - t1);
    return action(self, req, res);
}

/// newState(newState, emitEvent) will transition to a new state, and emit the given event
/// which will awaken all the SSE event stream threads
/// This will also reset the countdown clock
/// MUTEX - you MUST have the mutex locked before calling set state
fn newState(self: *Self, new_state: State, emit_event: Event) void {
    // locks the event_mutex (not the game_mutex) - so that it can broadcast all event threads
    self.event_mutex.lock();
    self.last_event = emit_event;
    self.state = new_state;
    const new_expiry_time = std.time.timestamp() + self.countdown_timer;
    if (self.expiry_time < new_expiry_time) {
        self.expiry_time = new_expiry_time;
    }
    self.event_condition.broadcast();
    self.event_mutex.unlock();

    std.log.info("{}: signal event {}", .{ std.time.timestamp(), emit_event });
}

/// reboot will reboot the server back to the vanilla state. Call this when everything has timed out, and we want to go right back to the original start
fn reboot(self: *Self) void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    self.grid_x = 3;
    self.grid_y = 3;
    self.number_of_players = 2;
    self.needed_to_win = 3;
    self.zero_wing_chance = 0;
    self.expiry_time = std.time.timestamp() + initial_countdown_timer;
    self.zapLogins();
    self.newState(.init, .init);
}

/// restart will set the game back to the setup phase, using the current Game parameters
fn restart(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    res.body = "restarted";
    self.countdown_timer = start_countdown_timer;
    self.expiry_time = std.time.timestamp() + initial_countdown_timer;
    self.zapLogins();
    self.newState(.init, .init);
}

/// clock() function emits an event of type clock with the current number of remaining seconds until the next expiry time
fn clock(self: *Self, stream: std.net.Stream) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    const w = stream.writer();
    try w.writeAll("event: clock\n");
    const remaining = self.expiry_time - std.time.timestamp();
    if (self.state == .running and remaining > 0) {
        try w.print("data: {d} seconds remaining ...\n\n", .{remaining});
    } else {
        try w.writeAll(" \n\n"); // blank out the clock countdown element on the client
    }
}

/// getPlayer is a utility function to extract the player ID from the request header
/// the X-PLAYER header is passed as a UUID, which we decode into a player ID 1-number_of_players
/// or 0 if there is no valid player in the X-PLAYER header
/// Also will return 0 if the player is valid, but not registered as logged in, which
/// prevents old player UUIDs from being re-used
fn getPlayer(self: *Self, req: *httpz.Request) u8 {
    const none: u8 = 0;
    const player_uuid_string = req.headers.get("x-player") orelse return none;
    const player_uuid = uuid.UUID.parse(player_uuid_string) catch return none;
    if (player_uuid.match(uuid.zero)) return none;

    for (0..self.number_of_players) |p| {
        if (player_uuid.match(self.logged_in[p])) {
            return @intCast(p + 1);
        }
    }
    return 0;
}

/// zeroWing handler to get the background image
fn zeroWing(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = self;
    _ = req;
    res.body = @embedFile("images/zero-wing-gradient.jpg");
}

fn yourTurnAudio(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = self;
    _ = req;
    res.header("Content-Type", "audio/mpeg");
    res.body = @embedFile("audio/your-turn.mp3");
}

fn zeroWingAudio(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = self;
    _ = req;
    res.header("Content-Type", "audio/mpeg");
    res.body = @embedFile("audio/zero-wing.mp3");
}

fn nukeAudio(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = self;
    _ = req;
    res.header("Content-Type", "audio/mpeg");
    res.body = @embedFile("audio/nuke.mp3");
}

fn victoryAudio(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = self;
    _ = req;
    res.header("Content-Type", "audio/mpeg");
    res.body = @embedFile("audio/victory.mp3");
}

fn lostAudio(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = self;
    _ = req;
    res.header("Content-Type", "audio/mpeg");
    res.body = @embedFile("audio/lost.mp3");
}

/// calcAudio calculates the name of the audio element that matches the current user state
fn calcAudio(self: *Self, player: u8) []const u8 {
    if (player == self.current_player) {
        return switch (self.player_mode) {
            .normal => "<script>sing(yourTurnAudio, 1)</script>",
            .zeroWing => "<script>sing(zeroWingAudio, 1)</script>",
            .nuke => "<script>sing(nukeAudio, 1)</script>",
        };
    }
    return "";
}

/// header() GET req returns the title header, depending on the game state
fn header(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    const player = self.getPlayer(req);
    const tmpl = @embedFile("html/header/template.html");

    switch (self.state) {
        .init => {
            res.body = zts.s(tmpl, "init");
        },
        .login => {
            res.body = zts.s(tmpl, "login");
        },
        .running => {
            try zts.print(tmpl, "running", .{
                .current_player = self.current_player,
                .audio = self.calcAudio(player),
            }, res.writer());
        },
        .winner => {
            if (player == self.current_player) {
                res.body = zts.s(tmpl, "winner-victory");
            } else {
                res.body = zts.s(tmpl, "winner-lost");
            }
        },
        .stalemate => {
            res.body = zts.s(tmpl, "stalemate");
        },
    }
}

/// app()  GET req returns the main app body, depending on the current state of the game, and the player
fn app(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    const player = self.getPlayer(req);

    switch (self.state) {
        .init => {
            const tmpl = @embedFile("html/setup_game.html");
            try zts.print(tmpl, "form", .{
                .x = self.grid_x,
                .y = self.grid_y,
                .players = self.number_of_players,
                .win = self.needed_to_win,
                .zero_wing = self.zero_wing_chance,
                .nuke = self.nuke_chance,
            }, res.writer());
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
            try res.writer().writeAll(@embedFile("html/widgets/restart-button.html"));
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
            .zeroWing => "active-player-flip",
            .nuke => "active-player-nuke",
        };
    }
    return "inactive-player";
}

/// showBoard writes the current board to the HTTP response, based on the current player and what state they are in
fn showBoard(self: *Self, player: u8, res: *httpz.Response) !void {
    const w = res.writer();

    const tmpl = @embedFile("html/board/template.html");

    try zts.printHeader(tmpl, .{
        .class = self.calcBoardClass(player),
        .columns = self.grid_x,
    }, w);

    for (0..self.grid_y) |y| {
        for (0..self.grid_x) |x| {
            const value = self.board.get(x, y) catch |err| blk: {
                std.log.info("get {} {} gives error {}", .{ x, y, err });
                break :blk 0;
            };

            // used square that we cant normally click on
            if (value != 0) {
                if (self.player_mode == .zeroWing and self.state == .running and player == self.current_player) {
                    // BUT ! we have zeroWing powers this turn, so we can change another player's piece to our piece !
                    try zts.print(tmpl, "clickable", .{
                        .class = "grid-square-clickable",
                        .x = x + 1,
                        .y = y + 1,
                        .player = value,
                    }, w);
                    continue;
                }

                try zts.print(tmpl, "square", .{
                    .class = "grid-square",
                    .player = value,
                }, w);
                continue;
            }

            // we are the active player, and the square is not used yet
            if (self.state == .running and player == self.current_player) {
                try zts.print(tmpl, "clickable", .{
                    .class = "grid-square-clickable",
                    .x = x + 1,
                    .y = y + 1,
                    .player = value,
                }, w);
                continue;
            }

            // empty square that we cant click on,because its not your turn
            try zts.print(tmpl, "square", .{
                .class = "grid-square",
                .player = value,
            }, w);
        }
    }

    // try w.writeAll(@embedFile("html/board/end-grid.html"));
    try zts.write(tmpl, "end", w);

    if (self.current_player == player) {
        switch (self.player_mode) {
            .normal => try zts.write(tmpl, "your-move", w),
            .zeroWing => try zts.write(tmpl, "zero-wing-enabled", w),
            .nuke => try zts.write(tmpl, "set-us-up-the-bomb", w),
        }
    }

    return;
}

/// isLoggedIn returns true/false if the given player is logged in.
/// Pass playerID in the range 1..MAX
fn isLoggedIn(self: *Self, player: usize) bool {
    if (player < 1 or player > self.number_of_players) return false;
    return !uuid.zero.match(self.logged_in[player - 1]);
}

/// loginForm() handler returns either a login form, or a display of who we are waiting for if the user is logged in
fn loginForm(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const w = res.writer();
    const player = self.getPlayer(req);

    if (player > 0) {
        const wait_tmpl = @embedFile("html/login/waiting.html");
        try zts.writeHeader(wait_tmpl, w);
        for (0..self.number_of_players) |p| {
            if (!self.isLoggedIn(p + 1)) {
                try zts.print(wait_tmpl, "waiting-player", .{
                    .player = p + 1,
                }, w);
            }
        }
        return;
    }

    const form_tmpl = @embedFile("html/login/form.html");
    try zts.writeHeader(form_tmpl, w);

    for (0..self.number_of_players) |p| {
        if (!self.isLoggedIn(p + 1)) {
            try zts.print(form_tmpl, "select-player", .{
                .player = p + 1,
            }, w);
        }
    }
}

/// login() POST handler logs this player in, and returns the playerID
fn login(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    const player_value = req.param("player").?;
    const player = try std.fmt.parseInt(u8, player_value, 10);

    if (player < 1 or player > self.number_of_players) {
        res.status = 401;
        res.body = "Invalid Player";
        return;
    }
    if (self.isLoggedIn(player)) {
        res.status = 401;
        res.body = "That player is already logged in";
    }

    const new_player_uuid = uuid.newV4();
    self.logged_in[player - 1] = new_player_uuid;
    std.log.info("Player {} now logged in", .{player});
    try res.writer().print("{}", .{new_player_uuid});

    // if everyone is logged in, then proceed to the .running state, and signal .start
    // othervise, signal that a login happened, but we are still waiting for everyone to join
    var all_logged_in = true;
    for (0..self.number_of_players) |p| {
        if (!self.isLoggedIn(p + 1)) {
            all_logged_in = false;
            break;
        }
    }
    if (all_logged_in) {
        std.log.info("Everyone is now logged in", .{});
        self.current_player = 1;
        self.expiry_time = std.time.timestamp() + start_countdown_timer;
        self.countdown_timer = start_countdown_timer;
        self.newState(.running, .start);
    } else {
        self.newState(self.state, .login);
    }
}

/// square POST handler - user has clicked on a square to place their peice and end their turn
fn square(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    if (self.state != .running) {
        res.status = 401;
        res.body = "Game not running";
        return;
    }

    const x = std.fmt.parseInt(usize, req.param("x").?, 10) catch 0;
    const y = std.fmt.parseInt(usize, req.param("y").?, 10) catch 0;

    const player = self.getPlayer(req);

    if (player < 1 or player > self.number_of_players) {
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
        self.newState(.winner, .victory);
        return;
    }

    if (self.board.is_full()) {
        std.log.info("Board is full - stalemate !", .{});
        res.body = "Stalemate";
        self.newState(.stalemate, .stalemate);
        return;
    }

    self.current_player += 1;
    if (self.current_player > self.number_of_players) {
        self.current_player = 1;
    }

    // end of turn
    self.player_mode = self.randPlayerMode();
    if (self.countdown_timer > 1) {
        self.countdown_timer -= 1;
    }
    self.newState(.running, .next);
}

/// setup() POST request will set us up a new game, with specified grid size and number of players
fn setup(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    _ = res;
    self.game_mutex.lock();
    defer self.game_mutex.unlock();

    const SetupRequest = struct {
        x: u8,
        y: u8,
        players: u8,
        win: u8,
        zero_wing: u8,
        nuke: u8,
    };

    // sanity check the inputs !
    if (try req.json(SetupRequest)) |setup_request| {
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
        self.number_of_players = setup_request.players;
        self.needed_to_win = setup_request.win;
        self.zero_wing_chance = setup_request.zero_wing;
        self.nuke_chance = setup_request.nuke;

        self.player_mode = self.randPlayerMode();

        self.board = try Board.init(self.grid_x, self.grid_y);
        self.zapLogins();
        self.newState(.login, .wait);
    }
}

/// events GET handler is an SSE stream that emits events whenever the state changes
/// or a clock event expires. Uses the Game.event_condition to synch with the outer threads
fn events(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.timestamp();
    _ = req;

    errdefer {
        std.log.info("(event-source) started at {} now exiting", .{start_time});
    }

    res.disown();
    const stream = try res.startEventStream();
    const thread = try std.Thread.spawn(.{}, eventsLoop, .{ self, stream });
    thread.detach();
}

fn eventsLoop(self: *Self, stream: anytype) !void {
    // on initial connect, send the clock details, and send the last event processed
    try self.clock(stream);
    try stream.writer().print("event: update\ndata: {s}\n\n", .{@tagName(self.last_event)});

    // aquire a lock on the event_mutex
    self.event_mutex.lock();
    defer self.event_mutex.unlock();

    while (true) {
        const next_clock: u64 = switch (self.state) {
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
            if (self.last_event == .login or self.last_event == .start) {
                // this is a bit nasty - on a login event, need to wait a short time to let the
                // login handler flush itself so the client can get it's new player ID
                // before we signal the frontend that a new login event has happened
                std.time.sleep(std.time.ns_per_ms * 200);
            }
            try stream.writer().print("event: update\ndata: {s}\n\n", .{@tagName(self.last_event)});
        }
    }
}
