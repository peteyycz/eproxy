#include <fcntl.h>
#include <liburing/io_uring.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#define EXIT_SUCCESS 0
#define EXIT_ERROR 1

#include <liburing.h>

#define QUEUE_DEPTH 2
#define CUSTOM_BLOCK_SIZE 1024 * 4

int main(int argc, char *argv[]) {
  struct io_uring ring;
  char buffer[CUSTOM_BLOCK_SIZE];
  int fd;
  int ret;
  struct io_uring_sqe *sqe;
  struct io_uring_cqe *cqe;
  ssize_t bytes_read_total = 0;
  off_t offset = 0;

  if (argc < 2) {
    fprintf(stderr, "Usage: %s <filename>\n", argv[0]);
    return EXIT_ERROR;
  }

  const char *filename = argv[1];

  ret = io_uring_queue_init(QUEUE_DEPTH, &ring, 0);
  if (ret < 0) {
    fprintf(stderr, "io_uring_queue_init failed %s\n", strerror(-ret));
    return EXIT_ERROR;
  }

  fd = open(filename, O_RDONLY);
  if (fd < 0) {
    perror("open");
    io_uring_queue_exit(&ring);
    return EXIT_ERROR;
  }

  printf("Reading file %s\n", filename);

  while (true) {
    sqe = io_uring_get_sqe(&ring);
    if (!sqe) {
      fprintf(stderr, "Cannot get sqe %d", fd);
      close(fd);
      io_uring_queue_exit(&ring);
      return EXIT_ERROR;
    }

    io_uring_prep_read(sqe, fd, buffer, 1, offset);

    ret = io_uring_submit(&ring);
    if (ret < 0) {
      fprintf(stderr, "io_uring_submit error %s\n", strerror(-ret));
      close(fd);
      io_uring_queue_exit(&ring);
      return EXIT_ERROR;
    }

    ret = io_uring_wait_cqe(&ring, &cqe);
    if (ret < 0) {
      fprintf(stderr, "io_uring_wait_cqe error %s\n", strerror(-ret));
      close(fd);
      io_uring_queue_exit(&ring);
      return EXIT_ERROR;
    }

    if (cqe->res < 0) {
      if (cqe->res == -ENOBUFS) {
        fprintf(stderr, "read failed %s. out of buffers? \n",
                strerror(-cqe->res));
      } else {
        fprintf(stderr, "read failed %s\n", strerror(-cqe->res));
      }
      io_uring_cqe_seen(&ring, cqe);
      close(fd);
      io_uring_queue_exit(&ring);
      return EXIT_ERROR;
    }

    ssize_t bytes_read = cqe->res;

    if (bytes_read == 0) {
      io_uring_cqe_seen(&ring, cqe);
      break;
    }

    printf("%.*s", (int)bytes_read, buffer);

    bytes_read_total += bytes_read;
    offset += bytes_read;

    io_uring_cqe_seen(&ring, cqe);
  }

  printf("total bytes read %zd\n", bytes_read_total);

  close(fd);
  io_uring_queue_exit(&ring);

  return EXIT_SUCCESS;
}
