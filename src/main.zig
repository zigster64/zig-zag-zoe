const std = @import("std");
const httpz = @import("httpz");
const Game = @import("game.zig");

const www_path = "www"; // set this to the base path where the WebApp lives

pub fn usage() void {
    std.debug.print("USAGE: zig-zag-zoe [-p PORTNUMBER]\n", .{});
    std.debug.print("       or use the PORT env var to set the port, for like Docker or whatever\n", .{});
}

pub fn main() !void {
    var port: u16 = 3000;

    var env_port = std.os.getenv("PORT");
    if (env_port != null and env_port.?.len > 0) {
        port = try std.fmt.parseInt(u16, env_port.?, 10);
        std.debug.print("Port set to {} via ENV\n", .{port});
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

    std.debug.print("Starting Zig-Zag-Zoe server with new game.\n", .{});
    std.debug.print("Go to http://localhost:{} to run the game\n", .{port});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // TODO - allow grid size and player count to be config params
    var grid_x: u8 = 3;
    var grid_y: u8 = 3;
    var players: u8 = 2;
    var win: u8 = 3;

    var game = try Game.init(grid_x, grid_y, players, win);

    var server = try httpz.ServerCtx(*Game, *Game).init(allocator, .{
        .address = "0.0.0.0",
        .port = port,
    }, &game);
    // server.notFound(fileServer);
    server.notFound(notFound);
    server.errorHandler(errorHandler);

    var router = server.router();
    router.get("/", indexHTML);
    router.get("/index.html", indexHTML);
    router.get("/styles.css", stylesCSS);

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

fn fileServer(ctx: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    _ = ctx;
    const path = req.url.path;
    std.debug.print("GET {s}\n", .{path});

    var new_path = try std.mem.concat(res.arena, u8, &[_][]const u8{ www_path, path });
    var index_file = std.fs.cwd().openFile(new_path, .{}) catch {
        res.status = 404;
        res.body = "File not found";
        return;
    };
    defer index_file.close();
    res.body = try index_file.readToEndAlloc(res.arena, 1 * 1024 * 1024); // 1MB should be enough for anyone !
}
