const std = @import("std");
const testing = std.testing;
const v = @import("validate");

const ValidateBaseFields = .{
    .jsonrpc = v.slice.equals("2.0"),
    .method = v.slice.min_length(1),
};

const RPCId = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
};

const RPCBase = struct {
    jsonrpc: [3]u8,
    method: []u8,
    id: ?RPCId,
};

fn Handler(comptime handle_func: type) type {
    return struct {
        method: []const u8,
        params: type,
        handle: handle_func,
    };
}

const ValidateHandler = .{
    .method = v.combinator._not(v.slice.begins_with("rpc.")),
};

fn handler(comptime method: []const u8, comptime params: type, comptime handle: anytype) Handler(@TypeOf(handle)) {
    comptime var h: Handler(@TypeOf(handle)) = .{ .method = method, .params = params, .handle = handle };
    comptime {
        switch (@typeInfo(params)) {
            .Array => {},
            .Struct => {},
            .Void => {},
            else => @compileError("Invalid params type. Must be an array or struct or void."),
        }
        if (!v.validate(ValidateHandler, h)) {
            const formatStr = "Invalid method name: '{s}'. Method names must not begin with 'rpc.'.";
            const len = formatStr.len - 3 + method.len;
            var errorString: [len]u8 = undefined;
            _ = try std.fmt.bufPrint(&errorString, formatStr, .{method});

            @compileError(&errorString);
        }
    }

    return h;
}

// TODO: handle more internal errors
// TODO: handle error from handler func
// TODO: handle batch requests
// TODO: Fix double parse
// NOTE: null request id is treated as notification
fn handleMessage(comptime handlers: anytype, writer: anytype, message: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var stream = std.json.TokenStream.init(message);
    const parsedData = std.json.parse(RPCBase, &stream, .{ .allocator = allocator, .ignore_unknown_fields = true }) catch |err| {
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"},\"id\":null}");
        return err;
    };
    defer std.json.parseFree(RPCBase, parsedData, .{ .allocator = allocator });
    const isValid = v.validate(ValidateBaseFields, parsedData);
    if (!isValid) {
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"},\"id\":");
        if (parsedData.id) |id| {
            try std.json.stringify(id, .{}, writer);
        } else {
            try writer.writeAll("null");
        }

        try writer.writeAll("}");
        return;
    }

    inline for (handlers) |handle| {
        if (std.mem.eql(u8, handle.method, parsedData.method)) {
            const data = switch (@typeInfo(handle.params)) {
                .Void => handle.handle(),
                else => data: {
                    comptime var Params = struct {
                        params: handle.params,
                    };
                    var stream2 = std.json.TokenStream.init(message);
                    const params = std.json.parse(Params, &stream2, .{ .allocator = allocator, .ignore_unknown_fields = true }) catch |err| {
                        if (parsedData.id) |id| {
                            try writer.writeAll("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"Invalid params\"},\"id\":");
                            try std.json.stringify(id, .{}, writer);
                            try writer.writeAll("}");
                        }
                        return err;
                    };
                    defer std.json.parseFree(Params, params, .{ .allocator = allocator });
                    break :data handle.handle(params.params);
                },
            };

            // if id does not exist the request from client was a
            // notification, we must NOT respond to a notification
            if (parsedData.id) |id| {
                const fnReturnType = (@typeInfo(@TypeOf(handle.handle)).Fn.return_type orelse ?u8);
                const resultType = switch (fnReturnType) {
                    void => ?u8,
                    else => fnReturnType,
                };
                comptime var ReturnMessage = struct {
                    jsonrpc: []const u8,
                    id: RPCId,
                    result: resultType,
                };
                const result = switch (fnReturnType) {
                    void => null,
                    else => data,
                };
                const returnMessage = ReturnMessage{
                    .jsonrpc = "2.0",
                    .id = id,
                    .result = result,
                };

                try std.json.stringify(returnMessage, .{}, writer);
                return;
            }
        }
    }

    // if id does not exist the request from client was a
    // notification, we must NOT respond to a notification
    if (parsedData.id) |id| {
        // since we didn't handle the message we respond
        // with the standard method not found error
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":");
        try std.json.stringify(id, .{}, writer);
        try writer.writeAll("}");
    }
}

fn blah(params: [1]bool) bool {
    return params[0];
}

test "example" {
    const s =
        \\ {
        \\   "jsonrpc": "2.0", "method": "blah",
        \\   "id": 1, "params": [false]
        \\ }
    ;
    // TODO: we shouldn't have to pass in the params separately
    const blahHandler = handler("blah", [1]bool, blah);
    const file = try std.fs.cwd().createFile("test.json", .{ .read = true });
    defer file.close();
    try handleMessage(.{blahHandler}, file.writer(), s);
}
