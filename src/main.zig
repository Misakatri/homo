const std = @import("std");

const print = std.debug.print;

const qjs = @import("./qjs.zig");

const MAX_FILE_SIZE: usize = 1024 * 1024;

const fs = std.fs;
const mem = std.mem;

fn send(js_ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, args: [*c]qjs.JSValue) callconv(.C) qjs.JSValue {
    var j = qjs.JS_ToCString(js_ctx, args[0]);
    var jj = std.mem.span(j);
    print("{s}\n",.{jj});
    const allocator = std.heap.page_allocator;
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    var tree = parser.parse(jj) catch |err| {
        std.debug.print("error: {s}", .{@errorName(err)});
        return qjs.JS_NewInt64(js_ctx, 123);
    };

    var a = tree.root.Object.get("addedNodes").?;
    print("{}\n", .{a});

    return qjs.JS_NewInt64(js_ctx, 123);
}

fn evalFile(allocator: std.mem.Allocator, src: []u8) ![]u8 {
    var js_src = std.ArrayList(u8).init(allocator);
    var js_wtr = js_src.writer();
    _ = try js_wtr.print("{s}\x00", .{src[0..src.len]});
    const srcs = js_src.toOwnedSlice();
    return srcs;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var argIter = try std.process.argsWithAllocator(allocator);
    _ = argIter.next();
    const file = mem.span(argIter.next()) orelse return error.InvalidSource;
    const src = try fs.cwd().readFileAlloc(allocator, file, MAX_FILE_SIZE);
    defer allocator.free(src);

    const js_src = try evalFile(allocator, src);

    {
        const load_std =
            \\ import * as std from 'std';
            \\ import * as os from 'os';
            \\ globalThis.std = std;
            \\ globalThis.os = os;
        ;

        var js_runtime: *qjs.JSRuntime = qjs.JS_NewRuntime().?;
        defer qjs.JS_FreeRuntime(js_runtime);

        var js_context = qjs.JS_NewContext(js_runtime);
        defer qjs.JS_FreeContext(js_context);

        _ = qjs.js_init_module_std(js_context, "std");
        _ = qjs.js_init_module_os(js_context, "os");

        qjs.js_std_init_handlers(js_runtime);
        defer qjs.js_std_free_handlers(js_runtime);

        qjs.JS_SetModuleLoaderFunc(js_runtime, null, qjs.js_module_loader, null);

        qjs.js_std_add_helpers(js_context, 0, null);

        var global: qjs.JSValue = qjs.JS_GetGlobalObject(js_context);

        var sendfn: qjs.JSValue = qjs.JS_NewCFunction(js_context, send, "send", 1);
        defer qjs.JS_FreeValue(js_context, global);
        _ = qjs.JS_SetPropertyStr(js_context, global, "send", sendfn);

        const val = qjs.JS_Eval(js_context, load_std, load_std.len, "<input>", qjs.JS_EVAL_TYPE_MODULE);
        if (qjs.JS_IsException(val) > 0) {
            qjs.js_std_dump_error(js_context);
        }

        const val2 = qjs.JS_Eval(js_context, js_src.ptr, js_src.len - 1, "<file>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (qjs.JS_IsException(val2) > 0) {
            qjs.js_std_dump_error(js_context);
        }

        qjs.js_std_loop(js_context);
    }
}
