const std = @import("std");
const builtin = @import("builtin");
const y3_plist = @embedFile("y3.plist");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const approxEqAbs = std.math.approxEqAbs;
const assert = std.debug.assert;
const FieldType = std.meta.FieldType;
const fs = std.fs;
const log = std.log;
const net = std.net;
const print = std.debug.print;
const Timer = std.time.Timer;

const Command = enum {
    focus,
    move,
    run,
    stop,
    @"window-created",
    @"window-focused",
    @"start-service",
    @"stop-service",
    @"restart-service",
};

const Direction = enum(u8) {
    north = 1,
    south = 2,
    east = 3,
    west = 4,
};

const Domain = enum {
    window,
    space,
    display,
    query,
};

var path_yabai: []const u8 = undefined;

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    const arg1 = args.next() orelse return log.err("missing command argument.", .{});
    const command = std.meta.stringToEnum(Command, arg1) orelse return log.err("invalid action: {s}", .{arg1});
    const username = std.posix.getenv("USER") orelse return log.err("failed to get user name", .{});
    var buf_path: [64]u8 = undefined;
    const path_socket_y3 = try std.fmt.bufPrint(&buf_path, "/tmp/y3_{s}.socket", .{username});

    var buf_cmd: [5]u8 = .{ @intFromEnum(command), 0, 0, 0, 0 };
    switch (command) {
        .focus, .move => {
            const arg2 = args.next() orelse return log.err("missing direction argument", .{});
            const dir = std.meta.stringToEnum(Direction, arg2) orelse return log.err("invalid direction: {s}", .{arg2});
            buf_cmd[1] = @intFromEnum(dir);
        },
        .@"window-focused", .@"window-created" => {
            const arg2 = args.next() orelse return log.err("missing window ID argument.", .{});
            const id = std.fmt.parseUnsigned(u32, arg2, 10) catch |err| return log.err("invalid window id '{s}': {s}", .{ arg2, @errorName(err) });
            buf_cmd[1..].* = @bitCast(id);
        },
        .@"start-service" => return startService(username, path_socket_y3) catch |err| log.err("failed to start service: {s}", .{@errorName(err)}),
        .@"stop-service" => return stopService(username, path_socket_y3) catch |err| log.err("failed to stop service: {s}", .{@errorName(err)}),
        .@"restart-service" => return restartService(username, path_socket_y3) catch |err| log.err("failed to restart service: {s}", .{@errorName(err)}),
        .run => return init(path_socket_y3, username) catch |err| log.err("failed to init y3 service: {s}", .{@errorName(err)}),
        .stop => {},
    }
    const stream = net.connectUnixSocket(path_socket_y3) catch |err| return log.err("failed to connect to y3 socket: {s}", .{@errorName(err)});
    defer stream.close();
    try stream.writeAll(&buf_cmd);
}

fn init(path_socket_y3: []const u8, username: []const u8) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const gpa_alloc = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    if (net.connectUnixSocket(path_socket_y3) catch null) |s| {
        s.close();
        return log.err("y3 is already running, exiting", .{});
    }
    path_yabai = try std.fmt.allocPrint(gpa_alloc, "/tmp/yabai_{s}.socket", .{username});
    defer gpa_alloc.free(path_yabai);

    if (net.connectUnixSocket(path_yabai)) |s| {
        s.close();
    } else |err| {
        std.time.sleep(std.time.ns_per_s);
        log.err("failed to connect to yabai socket, check if yabai is running", .{});
        return err;
    }
    const addr_socket = try net.Address.initUnix(path_socket_y3);
    var server = try addr_socket.listen(.{});
    defer server.deinit();
    print("started listener...\n", .{});

    var arena = ArenaAllocator.init(gpa_alloc);
    defer arena.deinit();

    const Space = struct { index: u8, @"has-focus": bool };
    const spaces = try query(&arena, []Space, .spaces, .{"--display"});
    const space = for (spaces) |s| {
        if (s.@"has-focus") break s;
    } else return error.NoFocusedSpace;

    const index_tmp: u8 = if (space.index > 1) 1 else 2;
    try focus(.space, index_tmp);
    std.time.sleep(20 * std.time.ns_per_ms);
    try focus(.space, space.index);

    const WindowLocal = struct {
        id: u32,
        @"has-focus": bool,
        @"is-native-fullscreen": bool,
        @"can-resize": bool,
        @"is-floating": bool,
    };
    var id_win_focused: ?u32 = null;
    const windows_all = try query(&arena, []WindowLocal, .windows, .{});
    for (windows_all) |w| {
        if (w.@"has-focus") id_win_focused = w.id;
        if (!w.@"is-native-fullscreen" and w.@"can-resize" and w.@"is-floating") {
            try float(w.id);
            std.time.sleep(20 * std.time.ns_per_ms);
        }
    }
    _ = arena.reset(.free_all);
    const config = Config.load(gpa_alloc, username) catch |err| return log.err("failed to load configuration: {s}", .{@errorName(err)});
    defer config.deinit();
    coreLoop(&arena, &server, &config.value, id_win_focused);
}

fn coreLoop(arena: *ArenaAllocator, server: *net.Server, config: *const Config, id_win_focused_arg: ?u32) void {
    var id_win_focused: ?u32 = id_win_focused_arg;
    var id_win_other: ?u32 = null;
    var buf: [5]u8 = .{ 0, 0, 0, 0, 0 };
    while (true) {
        defer _ = arena.reset(.{ .retain_with_limit = 1024 * 16 });
        const conn = server.accept() catch |err| {
            log.err("failed to accept socket connection: {s}", .{@errorName(err)});
            continue;
        };
        defer conn.stream.close();

        _ = conn.stream.readAll(&buf) catch |err| {
            log.err("failed to read socket stream: {s}", .{@errorName(err)});
            continue;
        };
        const command: Command = @enumFromInt(buf[0]);
        switch (command) {
            .focus => {
                const dir: Direction = @enumFromInt(buf[1]);
                focusWindow(dir) catch |err| log.err("failed to 'focus window {s}': {s}", .{ @tagName(dir), @errorName(err) });
            },
            .move => {
                const dir: Direction = @enumFromInt(buf[1]);
                moveWindow(dir, arena) catch |err| log.err("failed to 'move window {s}': {s}", .{ @tagName(dir), @errorName(err) });
            },
            .@"window-created" => {
                const id_win_created: u32 = @bitCast(buf[1..].*);
                placeWindow(id_win_created, id_win_focused, id_win_other, config, arena) catch |err|
                    log.err("failed to place created window {}: {s}", .{ id_win_created, @errorName(err) });
            },
            .@"window-focused" => {
                id_win_other = id_win_focused;
                id_win_focused = @bitCast(buf[1..].*);
            },
            .stop => break,
            else => log.err("unsupported command sent to y3 server: {s}", .{@tagName(command)}),
        }
        if (builtin.mode == .Debug)
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        // log.debug("arena capacity: {}", .{arena.queryCapacity()});
    }
}

const Config = struct {
    allow_list: std.json.ArrayHashMap(?[]const []const u8),
    layout: enum { bsp, manual, two_columns },
    placement: enum { focused_window, other_window },

    fn load(gpa: Allocator, username: []const u8) !std.json.Parsed(Config) {
        const path = try std.fs.path.join(gpa, &.{ "/Users", username, ".config", "y3", "config.json" });
        defer gpa.free(path);
        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
            if (err == error.FileNotFound) log.err("failed to open {s}", .{path});
            return err;
        };
        const data = try file.readToEndAlloc(gpa, 1024);
        defer gpa.free(data);
        return std.json.parseFromSlice(Config, gpa, data, .{ .allocate = .alloc_always });
    }
};

fn placeWindow(id_win_created: u32, id_win_focused: ?u32, id_win_other: ?u32, config: *const Config, arena: *ArenaAllocator) !void {
    const WindowLocal = struct {
        app: []const u8,
        title: []const u8,
        @"can-resize": bool,
        @"is-native-fullscreen": bool,
    };
    const win_created = try query(arena, WindowLocal, .windows, .{ "--window", id_win_created });

    if (!win_created.@"can-resize" or win_created.@"is-native-fullscreen") return;
    if (config.allow_list.map.getEntry(win_created.app)) |entry| {
        if (entry.value_ptr.*) |titles| {
            for (titles) |title| if (std.mem.eql(u8, title, win_created.title)) return;
        } else return;
    }
    const Space = struct {
        type: []const u8,
        @"first-window": u32,
        @"last-window": u32,
    };
    const space = try query(arena, Space, .spaces, .{"--space"});

    if (space.@"first-window" == 0 or config.layout == .bsp or std.mem.eql(u8, space.type, "stack")) return float(id_win_created);
    if (std.mem.eql(u8, space.type, "float")) return; // includes native fullscreen
    if (space.@"first-window" == space.@"last-window") {
        const stream = try yabaiUnchecked(.window, .{ space.@"first-window", "--insert", Direction.east });
        defer stream.close();
        try float(id_win_created);
        return checkStreamError(stream);
    }
    const id_win_prev = (if (id_win_focused != id_win_created) id_win_focused else id_win_other) orelse return error.WindowOther;
    const id_win_target = switch (config.placement) {
        .focused_window => id_win_prev,
        .other_window => if (id_win_prev == space.@"last-window") space.@"first-window" else space.@"last-window",
    };
    return stackFocus(id_win_created, id_win_target);
}

fn focusWindow(dir_input: Direction) !void {
    focus(.window, dir_input) catch |err| switch (err) {
        error.WindowNorth, error.WindowSouth, error.WindowEast, error.WindowWest => {
            focusWindowInDisplay(dir_input) catch |err2| switch (err2) {
                error.DisplayNorth, error.DisplaySouth => try focusWindowInStack(dir_input),
                error.DisplayEast, error.DisplayWest => {},
                else => return err2,
            };
        },
        error.WindowSelected => focusWindowInDisplay(dir_input) catch {},
        else => return err,
    };
}

fn focusWindowInDisplay(dir_input: Direction) !void {
    try focus(.display, dir_input);
    const target = switch (dir_input) {
        .east, .south => "first",
        .west, .north => "last",
    };
    // TODO: test with 3 displays
    focus(.window, target) catch |err| log.err("failed to selectInDisplay, input: {}, {}", .{ dir_input, err });
}

fn focusWindowInStack(dir_input: Direction) !void {
    switch (dir_input) {
        .north => focus(.window, "stack.prev") catch |err| switch (err) {
            error.StackedPrev => focus(.window, "stack.last") catch |err2| switch (err2) {
                error.StackedLast => {},
                else => |e| return e,
            },
            else => return err,
        },
        .south => focus(.window, "stack.next") catch |err| switch (err) {
            error.StackedNext => focus(.window, "stack.first") catch |err2| switch (err2) {
                error.StackedFirst => {},
                else => |e| return e,
            },
            else => return err,
        },
        else => {},
    }
}

inline fn match(a: i16, b: i16) bool {
    return @abs(a - b) < 3;
}

fn moveWindow(dir_input: Direction, arena: *ArenaAllocator) !void {
    const windows = try query(arena, []Window, .windows, .{"--space"});
    const win: *const Window = for (windows) |*w| {
        if (w.@"has-focus") break w;
    } else return error.NoFocusedWindow;

    if (win.@"stack-index" > 0) return unstackFocus(win.id, dir_input) catch |err| switch (err) {
        error.WindowNonBsp => return moveToDisplay(arena, dir_input),
        else => return err,
    };
    const win_north = win.neighbor(.north, windows, dir_input);
    const win_south = win.neighbor(.south, windows, dir_input);
    const win_east = win.neighbor(.east, windows, dir_input);
    const win_west = win.neighbor(.west, windows, dir_input);

    if (switch (dir_input) {
        .north => win_north,
        .south => win_south,
        .east => win_east,
        .west => win_west,
    }) |win_target| {
        log.debug("target window: {any}", .{win_target});
        if (win_target.matches(win.frame)) return stackFocus(win.id, win_target.id);

        return switch (dir_input) {
            .north, .south => {
                if (match(win.frame.w, @divFloor(win_target.frame.w, 2))) {
                    if (match(win.frame.x, win_target.frame.x)) return insertWarp(win.id, win_target.id, .west, dir_input);
                    if (match(win.frame.x2, win_target.frame.x2)) return insertWarp(win.id, win_target.id, .east, dir_input);
                }
            },
            .east, .west => {
                if (win_north == null and win_south == null) { // is full height
                    if (win_target.isFullHeight(windows, dir_input)) return stackFocus(win.id, win_target.id);
                }
                if (win_north == null) { // is top
                    if (match(win.frame.w, win_south.?.frame.w)) return insertWarp(win.id, win_south.?.id, dir_input, .south);
                }
                if (win_south == null) { // is bottom
                    if (match(win.frame.w, win_north.?.frame.w)) return insertWarp(win.id, win_north.?.id, dir_input, .north);
                }
            },
        };
    }

    if (win_north == null and win_south == null and // is maximized
        win_east == null and win_west == null) return moveToDisplay(arena, dir_input);

    if (win_north == null and win_south == null) return switch (dir_input) { // is full height
        .east, .west => return moveToDisplay(arena, dir_input),
        .north, .south => {
            if (win_east == null) { // is right
                if (win_west.?.matches(win.frame)) return insertWarp(win.id, win_west.?.id, dir_input, .west);
            }
            if (win_west == null) { // is left
                if (win_east.?.matches(win.frame)) return insertWarp(win.id, win_east.?.id, dir_input, .east);
            }
        },
    };
    if (win_east == null and win_west == null) return switch (dir_input) { // is full width
        .north, .south => return moveToDisplay(arena, dir_input),
        .east, .west => {
            if (win_north == null) {
                if (win_south.?.isFullWidth(windows, dir_input)) return insertWarp(win.id, win_south.?.id, dir_input, .south);
            }
            if (win_south == null) {
                if (win_north.?.isFullWidth(windows, dir_input)) return insertWarp(win.id, win_north.?.id, dir_input, .north);
            }
        },
    };
    if (win_north == null) { // is top
        return if (match(win.frame.w, win_south.?.frame.w)) insertWarp(win.id, win_south.?.id, dir_input, .south);
    }
    if (win_south == null) { // is bottom
        return if (match(win.frame.w, win_north.?.frame.w)) insertWarp(win.id, win_north.?.id, dir_input, .north);
    }
}

fn moveToDisplay(arena: *ArenaAllocator, dir_input: Direction) !void {
    const Space = struct {
        @"first-window": u32,
        @"last-window": u32,
        @"is-visible": bool,
        @"is-native-fullscreen": bool,
    };
    const spaces = query(arena, []Space, .spaces, .{ "--display", dir_input }) catch |err| switch (err) {
        error.DisplayNorth => return if (dir_input != .north) err,
        error.DisplaySouth => return if (dir_input != .south) err,
        error.DisplayEast => return if (dir_input != .east) err,
        error.DisplayWest => return if (dir_input != .west) err,
        else => return err,
    };
    const space = for (spaces) |s| {
        if (s.@"is-visible") break s;
    } else return error.NoTargetSpace;

    if (space.@"is-native-fullscreen") return;
    if (space.@"first-window" == 0) return yabai(.window, .{ "--display", dir_input, "--focus" });

    const id_target: u32, const side_insert: Direction = switch (dir_input) {
        .north => .{ space.@"last-window", .south },
        .south => .{ space.@"last-window", .north },
        .east => .{ space.@"first-window", .west },
        .west => .{ space.@"last-window", .east },
    };
    const stream = try yabaiUnchecked(.window, .{ id_target, "--insert", side_insert });
    defer stream.close();

    try yabai(.window, .{ "--display", dir_input, "--focus" });
    try checkStreamError(stream);
}

fn focus(comptime domain: Domain, target: anytype) !void {
    try yabai(domain, .{ "--focus", target });
}

fn stackFocus(id_source: u32, target: anytype) !void {
    try yabai(.window, .{ target, "--stack", id_source });
    try yabai(.window, .{ "--focus", id_source });
}

fn unstackFocus(id_win: u32, dir_unstack: Direction) !void {
    try yabai(.window, .{ id_win, "--insert", dir_unstack, "--toggle", "float", "--toggle", "float", "--focus" });
}

fn insertWarp(id_source: u32, id_target: u32, side_insert: Direction, dir_warp: Direction) !void {
    const stream = try yabaiUnchecked(.window, .{ id_target, "--insert", side_insert });
    defer stream.close();
    try yabai(.window, .{ id_source, "--warp", dir_warp });
    try checkStreamError(stream);
}

fn float(id_win: u32) !void {
    try yabai(.window, .{ id_win, "--toggle", "float" });
}

fn query(
    arena: *ArenaAllocator,
    comptime Parsed: type,
    comptime cmd: enum { displays, spaces, windows },
    args: anytype,
) !Parsed {
    const fields = std.meta.fields(switch (@typeInfo(Parsed)) {
        .Struct => Parsed,
        .Pointer => |p| switch (@typeInfo(p.child)) {
            .Struct => p.child,
            else => @compileError("unsupported type: " ++ @typeName(p.child)),
        },
        else => @compileError("unsupported type: " ++ @typeName(@TypeOf(Parsed))),
    });
    comptime var count_fields = 0;
    inline for (fields) |field| {
        if (field.default_value == null) count_fields += 1;
    }
    comptime var fields_string: []const u8 = "";
    inline for (fields, 0..) |field, i| {
        if (field.default_value) |_| continue;
        fields_string = fields_string ++ field.name;
        if (i < count_fields - 1) fields_string = fields_string ++ ",";
    }
    const stream = try yabaiUnchecked(.query, .{"--" ++ @tagName(cmd)} ++ .{fields_string} ++ args);
    defer stream.close();
    const arena_alloc = arena.allocator();
    const buf = try stream.reader().readAllAlloc(arena_alloc, 8192);
    var parsed = std.json.parseFromSliceLeaky(Parsed, arena_alloc, buf, .{ .ignore_unknown_fields = true }) catch |err| {
        try findSendError(buf);
        return err;
    };
    if (@hasField(Parsed, "frame")) {
        if (@hasField(FieldType(Parsed, .frame), "x2") and @hasField(FieldType(Parsed, .frame), "y2")) {
            parsed.frame.x2 = parsed.frame.x + parsed.frame.w;
            parsed.frame.y2 = parsed.frame.y + parsed.frame.h;
        }
    } else if (@typeInfo(Parsed) == .Pointer) {
        const type_child = @typeInfo(Parsed).Pointer.child;
        if (@hasField(type_child, "frame")) {
            if (@hasField(FieldType(type_child, .frame), "x2") and @hasField(FieldType(type_child, .frame), "y2")) {
                for (parsed) |*p| {
                    p.*.frame.x2 = p.frame.x + p.frame.w;
                    p.*.frame.y2 = p.frame.y + p.frame.h;
                }
            }
        }
    }
    return parsed;
}

fn yabai(comptime domain: Domain, args: anytype) !void {
    const stream = try yabaiUnchecked(domain, args);
    defer stream.close();
    try checkStreamError(stream);
}

fn yabaiUnchecked(comptime domain: Domain, args: anytype) !net.Stream {
    var buf = comptime std.BoundedArray(u8, 128).fromSlice([_]u8{ 0, 0, 0, 0 } ++ @tagName(domain) ++ [_]u8{0}) catch unreachable;
    inline for (args) |arg| {
        switch (@TypeOf(arg)) {
            Direction => buf.appendSliceAssumeCapacity(@tagName(arg)),
            else => |T| switch (@typeInfo(T)) {
                .Pointer => buf.appendSliceAssumeCapacity(arg),
                .Int => try buf.writer().print("{d}", .{arg}),
                else => @compileError("unsupported type: " ++ @typeName(@TypeOf(arg))),
            },
        }
        buf.appendAssumeCapacity(0);
    }
    buf.appendAssumeCapacity(0);
    const data = buf.slice();
    data[0] = @intCast(buf.len - 4);
    const stream = try net.connectUnixSocket(path_yabai);
    errdefer stream.close();
    try stream.writeAll(data);
    return stream;
}

fn checkStreamError(stream: net.Stream) !void {
    var buf: [128]u8 = undefined;
    const len = try stream.readAll(&buf);
    if (len > 0) try findSendError(buf[0..len]);
}

inline fn findSendError(buf: []const u8) !void {
    if (buf[0] == 7) return error_map.get(buf[1 .. buf.len - 1]) orelse {
        defer log.err("{s} [yabai reply]", .{buf[1 .. buf.len - 1]});
        if (std.mem.indexOf(u8, buf, "unknown command")) |_| return error.UnknownCommand;
        if (std.mem.indexOf(u8, buf, "unknown option")) |_| return error.UnknownOption;
        if (std.mem.indexOf(u8, buf, "could not locate window with the specified id")) |_| return error.WindowID;
        return error.UnsupportedError;
    };
}

const Window = struct {
    frame: Frame,
    id: u32,
    @"stack-index": u8,
    @"has-focus": bool,

    const Frame = struct {
        x: i16,
        y: i16,
        w: i16,
        h: i16,
        x2: i16 = undefined,
        y2: i16 = undefined,
    };
    const margin = 4;

    fn matches(self: *const Window, other: Window.Frame) bool {
        return @abs(self.frame.w - other.w) < margin and @abs(self.frame.h - other.h) < margin;
    }
    // TODO: test on multiple displays
    fn isFullHeight(self: *const Window, windows: []const Window, dir_input: Direction) bool {
        const win_north = self.neighbor(.north, windows, dir_input);
        const win_south = self.neighbor(.south, windows, dir_input);
        return if (win_north == null and win_south == null) true else false;
    }

    fn isFullWidth(self: *const Window, windows: []const Window, dir_input: Direction) bool {
        const win_east = self.neighbor(.east, windows, dir_input);
        const win_west = self.neighbor(.west, windows, dir_input);
        return if (win_east == null and win_west == null) true else false;
    }

    fn isTop(self: *const Window, windows: []const Window, dir_input: Direction) bool {
        return if (self.neighbor(.north, windows, dir_input)) |_| false else true;
    }

    fn isBottom(self: *const Window, windows: []const Window, dir_input: Direction) bool {
        return if (self.neighbor(.south, windows, dir_input)) |_| false else true;
    }

    fn isRight(self: *const Window, windows: []const Window, dir_input: Direction) bool {
        return if (self.neighbor(.east, windows, dir_input)) |_| false else true;
    }

    fn isLeft(self: *const Window, windows: []const Window, dir_input: Direction) bool {
        return if (self.neighbor(.west, windows, dir_input)) |_| false else true;
    }

    fn neighbor(self: *const Window, comptime dir_target: Direction, windows: []const Window, dir_input: Direction) ?*const Window {
        switch (dir_input) {
            inline else => |dir_input_comptime| {
                comptime var filter: struct { []const u8, []const u8 } = undefined;
                comptime var cond_a: []const u8 = undefined;
                comptime var cond_b: []const u8 = undefined;
                comptime var cond_c: struct { []const u8, []const u8 } = undefined;

                if (dir_target == .north or dir_target == .south) {
                    filter = if (dir_target == .north) .{ "y", "y2" } else .{ "y2", "y" };
                    cond_a = if (dir_input_comptime == .west) "x" else "x2";
                    cond_b = if (dir_input_comptime == .west) "x2" else "x";
                    cond_c = .{ "x", "x2" };
                } else {
                    filter = if (dir_target == .east) .{ "x2", "x" } else .{ "x", "x2" };
                    cond_a = if (dir_input_comptime == .south) "y2" else "y";
                    cond_b = if (dir_input_comptime == .south) "y" else "y2";
                    cond_c = .{ "y", "y2" };
                }
                var fallback: ?*const Window = null;
                for (windows) |*w| {
                    if (match(@field(self.frame, filter[0]), @field(w.frame, filter[1]))) {
                        if (match(@field(self.frame, cond_a), @field(w.frame, cond_a))) return w;
                        if (match(@field(self.frame, cond_b), @field(w.frame, cond_b))) {
                            fallback = w;
                            continue;
                        }
                        if (@field(self.frame, cond_c[0]) > @field(w.frame, cond_c[0]) and
                            @field(self.frame, cond_c[1]) < @field(w.frame, cond_c[1])) fallback = w;
                    }
                }
                return fallback;
            },
        }
    }
};

fn startService(username: []const u8, path_socket: []const u8) !void {
    if (net.connectUnixSocket(path_socket) catch null) |s| {
        s.close();
        return log.info("y3 is already running, exiting...", .{});
    }
    fs.deleteFileAbsolute(path_socket) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    const gpa = std.heap.c_allocator;
    const agent_path = try fs.path.join(gpa, &.{ "/Users", username, "Library", "LaunchAgents", "y3.plist" });
    defer gpa.free(agent_path);

    _ = fs.openFileAbsolute(agent_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            const agent_file = try fs.createFileAbsolute(agent_path, .{});
            defer agent_file.close();
            try agent_file.writeAll(y3_plist);
            log.info("installed y3 service: {s}", .{agent_path});
        },
        else => return log.err("failed to open y3.plist: {s}", .{@errorName(err)}),
    };
    var proc = std.process.Child.init(&.{ "launchctl", "load", agent_path }, gpa);
    _ = try proc.spawnAndWait();
    log.info("y3 service loaded...", .{});
}

fn stopService(username: []const u8, path_socket: []const u8) !void {
    const gpa = std.heap.c_allocator;
    const path_agent = try fs.path.join(gpa, &.{ "/Users", username, "Library", "LaunchAgents", "y3.plist" });
    defer gpa.free(path_agent);

    var proc = std.process.Child.init(&.{ "launchctl", "unload", path_agent }, gpa);
    _ = try proc.spawnAndWait();
    log.info("y3 service unloaded...", .{});
    try fs.deleteFileAbsolute(path_socket);
}

fn restartService(username: []const u8, path_socket: []const u8) !void {
    try stopService(username, path_socket);
    try startService(username, path_socket);
}

const error_map = std.StaticStringMap(YabaiError).initComptime(.{
    .{ "could not locate a northward managed window.", error.WindowNorth },
    .{ "could not locate a southward managed window.", error.WindowSouth },
    .{ "could not locate a eastward managed window.", error.WindowEast },
    .{ "could not locate a westward managed window.", error.WindowWest },
    .{ "could not locate the first managed window.", error.WindowFirst },
    .{ "could not locate the last managed window.", error.WindowLast },
    .{ "could not locate the next managed window.", error.WindowNext },
    .{ "could not locate the prev managed window.", error.WindowPrev },
    .{ "could not locate the next stacked window.", error.StackedNext },
    .{ "could not locate the prev stacked window.", error.StackedPrev },
    .{ "could not locate the first stacked window.", error.StackedFirst },
    .{ "could not locate the last stacked window.", error.StackedLast },
    .{ "could not locate a northward display.", error.DisplayNorth },
    .{ "could not locate a southward display.", error.DisplaySouth },
    .{ "could not locate a eastward display.", error.DisplayEast },
    .{ "could not locate a westward display.", error.DisplayWest },
    .{ "could not locate the selected window.", error.WindowSelected },
    .{ "could not locate the most recently focused window.", error.WindowRecent },
    .{ "the acting window is not within a bsp space.", error.WindowNonBsp },
});

const YabaiError = error{
    WindowNorth,
    WindowSouth,
    WindowEast,
    WindowWest,
    WindowFirst,
    WindowLast,
    WindowNext,
    WindowPrev,
    StackedNext,
    StackedPrev,
    StackedFirst,
    StackedLast,
    DisplayNorth,
    DisplaySouth,
    DisplayEast,
    DisplayWest,
    WindowSelected,
    WindowNonBsp,
    WindowRecent,
};
