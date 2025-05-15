#include <stdbool.h>
#include <stdio.h>

#define MAX_HANDLERS 10

enum event_t {
    EVENT_SHUTDOWN = 0
};

struct event_loop_t;

typedef void (*handler_func_t)(struct event_loop_t* loop);

typedef struct {
    handler_func_t handler;
    enum event_t event_type;
} handler_t;

typedef struct event_loop_t {
    bool is_running;

    int handler_count;
    handler_t handlers[MAX_HANDLERS];
} event_loop_t;

void on_shutdown(event_loop_t *loop, handler_func_t shutdown_handler) {
    loop->handlers[loop->handler_count] = (handler_t){shutdown_handler, EVENT_SHUTDOWN};
}

void on_shutdown_handler(event_loop_t* loop) {
    loop->is_running = false;
    printf("Shutting down...\n");
}

int main(int argc, char *argv[]) {
    event_loop_t loop = {
        .is_running = 1,
        .handler_count = 0,
    };

    on_shutdown(&loop, on_shutdown_handler);

    while (loop.is_running) {
        if (!loop.handler_count) {
            loop.handlers[loop.handler_count].handler(&loop);
            loop.handler_count--;
        }
    }
}
