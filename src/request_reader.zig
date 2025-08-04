const std = @import("std");
const log = std.log;
const headers = @import("headers.zig");

pub const RequestState = enum {
    reading,
    processing,
    terminal,

    pub fn isReading(self: RequestState) bool {
        return self == .reading;
    }

    pub fn isProcessing(self: RequestState) bool {
        return self == .processing;
    }

    pub fn isTerminal(self: RequestState) bool {
        return self == .terminal;
    }
};

pub const ReadingSubState = enum {
    headers,
    body,
};

pub const ProcessingSubState = enum {
    request,
    response,
};

pub const TerminalSubState = enum {
    completed,
    failed,
};

pub const RequestReader = struct {
    // Hierarchical state
    state: RequestState,
    reading_substate: ?ReadingSubState,
    processing_substate: ?ProcessingSubState,
    terminal_substate: ?TerminalSubState,

    // Data
    headers_buffer: std.ArrayList(u8),
    body_bytes_remaining: usize,
    parsed_headers: ?headers.Headers,

    pub fn init(arena_allocator: std.mem.Allocator) RequestReader {
        return RequestReader{
            .state = .reading,
            .reading_substate = .headers,
            .processing_substate = null,
            .terminal_substate = null,
            .headers_buffer = std.ArrayList(u8).init(arena_allocator),
            .body_bytes_remaining = 0,
            .parsed_headers = null,
        };
    }

    pub fn transitionTo(self: *RequestReader, new_state: RequestState, substate: anytype) void {
        // Clear old substates
        self.reading_substate = null;
        self.processing_substate = null;
        self.terminal_substate = null;

        // Set new state and substate
        self.state = new_state;
        switch (@TypeOf(substate)) {
            ReadingSubState => self.reading_substate = substate,
            ProcessingSubState => self.processing_substate = substate,
            TerminalSubState => self.terminal_substate = substate,
            else => {},
        }

        log.debug("State transition: {} -> {} (substate: {})", .{ self.state, new_state, substate });
    }

    pub fn isInState(self: *const RequestReader, state: RequestState, substate: anytype) bool {
        if (self.state != state) return false;

        return switch (@TypeOf(substate)) {
            ReadingSubState => if (self.reading_substate) |sub| sub == substate else false,
            ProcessingSubState => if (self.processing_substate) |sub| sub == substate else false,
            TerminalSubState => if (self.terminal_substate) |sub| sub == substate else false,
            else => true,
        };
    }

    pub fn deinit(self: *RequestReader) void {
        self.headers_buffer.deinit();
        if (self.parsed_headers) |*parsed| {
            parsed.deinit();
        }
    }
};