// Compile against the real patched UxPlay HTTP loop; use socketpair and an aged
// activity timestamp so wake-after-idle is exercised without a minute-long sleep.
#include <sys/socket.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int invalid_reads;
static ssize_t checked_recv(int fd, void *buf, size_t len, int flags) {
    if (fd < 0) invalid_reads++;
    return recv(fd, buf, len, flags);
}
#define recv checked_recv
#include "httpd.c"
#undef recv
static httpd_t *server;
static int requests;
static void log_line(void *ctx, int level, const char *msg) { (void)ctx; (void)level; fprintf(stderr, "%s\n", msg); }
static void request(void *ctx, http_request_t *req, http_response_t **res) {
    (void)ctx;
    if (strcmp(http_request_get_url(req), "/feedback") != 0) abort();
    requests++;
    *res = http_response_create();
    http_response_init(*res, "RTSP/1.0", 200, "OK");
    http_response_finish(*res, NULL, 0);
    server->running = 0;
}
static void destroy(void *ctx) { (void)ctx; server->running = 0; }
static int run_case(connection_type_t type, int quiet, bool peer_closed, bool expected) {
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) abort();
    logger_t *logger = logger_init();
    logger_set_level(logger, LOGGER_ERR);
    logger_set_callback(logger, log_line, NULL);
    httpd_callbacks_t callbacks = {.conn_request=request, .conn_destroy=destroy};
    server = httpd_init(logger, &callbacks, 0);
    server->server_fd4 = server->server_fd6 = -1;
    server->running = 1;
    server->open_connections = 1;
    server->connections[0].connected = 1;
    server->connections[0].user_data = server;
    server->connections[0].socket_fd = sockets[0];
    server->connections[0].type = type;
    server->connections[0].last_active = time(NULL) - quiet;
    requests = invalid_reads = 0;
    if (peer_closed) shutdown(sockets[1], SHUT_WR);
    else {
        const char *packet = "POST /feedback RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n";
        if (write(sockets[1], packet, strlen(packet)) != (ssize_t)strlen(packet)) abort();
    }
    alarm(5); // failure bound, not a timing dependency
    httpd_thread(server);
    alarm(0);
    char response[512] = {0};
    ssize_t n = read(sockets[1], response, sizeof(response)-1);
    bool ok = requests == (expected ? 1 : 0) && invalid_reads == 0;
    if (expected) ok = ok && n > 0 && strstr(response, "200 OK");
    printf("%s type=%d quiet=%ds peerClosed=%d requests=%d invalidReads=%d\n",
           ok ? "PASS" : "FAIL", type, quiet, peer_closed, requests, invalid_reads);
    close(sockets[1]);
    httpd_destroy(server);
    logger_destroy(logger);
    return ok ? 0 : 1;
}
int main(void) {
    int failures = 0;
    failures += run_case(CONNECTION_TYPE_RAOP, 1, false, true);
    failures += run_case(CONNECTION_TYPE_RAOP, 61, false, true);
    failures += run_case(CONNECTION_TYPE_RAOP, 299, false, true);
    failures += run_case(CONNECTION_TYPE_RAOP, 61, true, false);
    failures += run_case(CONNECTION_TYPE_UNKNOWN, 61, false, false);
    return failures ? 1 : 0;
}
