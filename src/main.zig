const std = @import("std");
const httpz = @import("httpz");
const Game = @import("game.zig");

const default_port = 3000;

// always log .info, even in release modes
pub const std_options = struct {
    pub const log_level = .info;
};

pub fn usage() void {
    std.debug.print("USAGE: zig-zag-zoe [-p PORTNUMBER]\n", .{});
    std.debug.print("       or use the PORT env var to set the port, for like Docker or whatever\n", .{});
}

pub fn main() !void {
    var port: u16 = default_port;

    var env_port = std.os.getenv("PORT");
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

    std.log.info("Starting Zig-Zag-Zoe server with new game", .{});
    std.log.info("Go to http://localhost:{} to run the game", .{port});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // TODO - allow grid size and player count to be config params
    var grid_x: u8 = 3;
    var grid_y: u8 = 3;
    var players: u8 = 2;
    var win: u8 = 3;
    var zero_wing: u8 = 0;

    var game = try Game.init(grid_x, grid_y, players, win, zero_wing);
    try game.startWatcher();

    var server = try httpz.ServerCtx(*Game, *Game).init(allocator, .{
        .address = "0.0.0.0",
        .port = port,
        .pool_size = Game.MAX_PLAYERS,
        .request = .{
            .max_body_size = 256,
        },
        .response = .{
            .body_buffer_size = 100_000, // big enough for the biggest audio file
            .header_buffer_size = 256,
        },
    }, &game);
    server.notFound(notFound);
    server.errorHandler(errorHandler);

    var router = server.router();
    router.get("/", indexHTML);
    router.get("/index.html", indexHTML);
    router.get("/styles.css", stylesCSS);
    router.get("/favicon.ico", favicon);

    // connect the game object to the router
    game.addRoutes(router);

    return server.listen();
}

// note that the error handler return `void` and not `!void`
fn errorHandler(ctx: *Game, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
    _ = ctx;
    res.status = 500;
    res.body = "Error";
    std.log.warn("Error {} on request {s}", .{ err, req.url.raw });
}

fn notFound(ctx: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    _ = ctx;
    res.status = 404;
    res.body = "File not found";
}

fn indexHTML(ctx: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    _ = ctx;
    res.body = @embedFile("html/index.html");
}

fn stylesCSS(ctx: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    _ = ctx;
    res.body = @embedFile("html/styles.css");
}

fn favicon(ctx: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    _ = ctx;
    res.body = @embedFile("images/favicon.ico");
}
