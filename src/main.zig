const std = @import("std");
const httpz = @import("httpz");
const Game = @import("game.zig");

const default_port = 3000;

// always log .info, even in release modes
// change this to .debug if you want extreme debugging
pub const std_options = std.Options{
    .log_level = .info,
};

pub fn usage() void {
    std.debug.print("USAGE: zig-zag-zoe [-p PORTNUMBER]\n", .{});
    std.debug.print("       or use the PORT env var to set the port\n", .{});
}

pub fn main() !void {
    var port: u16 = default_port;

    const env_port = std.posix.getenv("PORT");
    if (env_port != null and env_port.?.len > 0) {
        port = try std.fmt.parseInt(u16, env_port.?, 10);
        std.log.debug("Port set to {} via ENV\n", .{port});
    }

    var args = std.process.args();
    defer args.deinit();

    // parse params
    _ = args.skip();

    // parse any option commands
    while (args.next()) |arg| {
        std.debug.print("arg {s}\n", .{arg});
        if (std.mem.eql(u8, "-p", arg)) {
            const f = args.next() orelse {
                std.debug.print("Option -port must be followed by a port number to listen on\n", .{});
                usage();
                return;
            };
            port = try std.fmt.parseInt(u16, f, 10);
            std.debug.print("Port set to {} via parameters\n", .{port});
            continue;
        }
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    std.log.info("Starting Zig-Zag-Zoe server with new game", .{});

    try printValidAddresses(allocator, port);

    // TODO - allow grid size and player count to be config params
    const grid_x: u8 = 3;
    const grid_y: u8 = 3;
    const players: u8 = 2;
    const win: u8 = 3;
    const zero_wing: u8 = 0;

    var game = try Game.init(grid_x, grid_y, players, win, zero_wing);
    // try game.startWatcher();

    // std.log.debug("Setting pool size to {}", .{Game.MAX_PLAYERS * 4});
    var server = try httpz.ServerCtx(*Game, *Game).init(allocator, .{
        .address = "0.0.0.0",
        .port = port,
    }, &game);
    server.notFound(notFound);
    server.errorHandler(errorHandler);
    server.dispatcher(Game.logger);

    var router = server.router();
    router.get("/", indexHTML);
    router.get("/index.html", indexHTML);
    router.get("/htmx.min.js", htmx);
    router.get("/styles.css", stylesCSS);
    router.get("/favicon.ico", favicon);

    // test route to do a delay
    // router.get("/snooze", snooze);

    // connect the game object to the router
    game.addRoutes(router);

    std.log.info("[{}:{s}:{}] {s} {s}", .{ std.time.timestamp(), @tagName(game.state), 0, "BOOT", "Initial Startup" });
    return server.listen();
}

fn printValidAddresses(allocator: std.mem.Allocator, port: u16) !void {
    std.log.info("The game should be visible on any of these addresses:", .{});

    // do some digging to get a list of IPv4 addresses that we are listening on
    std.log.info("- http://localhost:{}", .{port});
    var hostBuffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try std.posix.gethostname(&hostBuffer);
    std.log.info("- http://{s}:{}", .{ hostname, port });

    var addressList = std.net.getAddressList(allocator, hostname, port) catch return;
    defer addressList.deinit();

    var uniqueIPv4Addresses = std.AutoHashMap(std.net.Ip4Address, bool).init(allocator);
    defer uniqueIPv4Addresses.deinit();

    for (addressList.addrs) |address| {
        if (address.any.family == std.posix.AF.INET) {
            try uniqueIPv4Addresses.put(address.in, true);
        }
    }

    var iter = uniqueIPv4Addresses.keyIterator();
    while (iter.next()) |address| {
        std.log.info("- http://{}", .{address});
    }
}

// note that the error handler return `void` and not `!void`
fn errorHandler(game: *Game, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
    game.logExtra(req, "(500 Error)");
    res.status = 500;
    res.body = "Error";
    std.log.err("Error {} on request {s}", .{ err, req.url.raw });
}

fn notFound(game: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    // std.log.info("Bad client {} tried for a thing not found - ban them", .{req.address.in.sa.addr});
    game.logExtra(req, "(404 Not Found)");
    res.status = 404;
    res.body = "File not found";
}

fn snooze(game: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    _ = res;
    _ = req;
    _ = game;
    std.time.sleep(std.time.ns_per_ms * 500);
}

fn indexHTML(game: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    game.log(req, 0);
    res.body = @embedFile("html/index.html");
}

fn htmx(game: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    game.log(req, 0);
    res.body = @embedFile("html/htmx.min.js");
}

fn stylesCSS(game: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    game.log(req, 0);
    res.body = @embedFile("html/styles.css");
}

fn favicon(game: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    game.log(req, 0);
    res.body = @embedFile("images/favicon.ico");
}
