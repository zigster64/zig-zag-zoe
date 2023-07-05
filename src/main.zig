const std = @import("std");
const httpz = @import("httpz");
const Game = @import("game.zig");

const www_path = "www"; // set this to the base path where the WebApp lives

pub fn main() !void {
    std.debug.print("Starting Zig-Zag-Zoe server with new game.\n", .{});
    std.debug.print("Go to http://localhost:3000 to run the game\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // TODO - allow grid size and player count to be config params
    var grid_x: u8 = 3;
    var grid_y: u8 = 3;
    var players: u8 = 2;

    var game = try Game.init(grid_x, grid_y, players);

    var server = try httpz.ServerCtx(*Game, *Game).init(allocator, .{ .port = 3000 }, &game);
    server.notFound(fileServer);

    var router = server.router();
    router.get("/", indexHTML);

    return server.listen();
}

fn fileServer(ctx: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    _ = ctx;
    return serveFile(res, req.url.path);
}

fn indexHTML(ctx: *Game, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    _ = ctx;
    return serveFile(res, "/index.html");
}

fn serveFile(res: *httpz.Response, path: []const u8) !void {
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
