#define SDL_MAIN_HANDLED
#include <SDL.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define READ_BUFFER_SIZE 4096
#define MAX_PACKET_SIZE (1024 * 1024)

static int parse_integer(const char *text, int minimum, int maximum, int *value) {
  char *end = NULL;
  long parsed = strtol(text, &end, 10);

  if (end == text || *end != '\0' || parsed < minimum || parsed > maximum) {
    return -1;
  }

  *value = (int)parsed;
  return 0;
}

static int fail_sdl(const char *operation) {
  fprintf(stderr, "beamicom audio: %s: %s\n", operation, SDL_GetError());
  return 1;
}

static int read_exact(int fd, unsigned char *buffer, size_t length) {
  while (length != 0) {
    ssize_t received = read(fd, buffer, length);

    if (received == 0) {
      return 0;
    }

    if (received < 0) {
      if (errno == EINTR) {
        continue;
      }

      return -1;
    }

    buffer += (size_t)received;
    length -= (size_t)received;
  }

  return 1;
}

static int write_exact(int fd, const unsigned char *buffer, size_t length) {
  while (length != 0) {
    ssize_t written = write(fd, buffer, length);

    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }

      return -1;
    }

    buffer += (size_t)written;
    length -= (size_t)written;
  }

  return 0;
}

static int queue_audio_bounded(SDL_AudioDeviceID device,
                               const unsigned char *pcm,
                               size_t length,
                               Uint32 max_queue_bytes,
                               size_t frame_bytes,
                               int *started) {
  while (length != 0) {
    Uint32 queued = SDL_GetQueuedAudioSize(device);
    Uint32 room = queued < max_queue_bytes ? max_queue_bytes - queued : 0;
    room -= room % frame_bytes;

    if (room == 0) {
      SDL_Delay(1);
      continue;
    }

    Uint32 chunk = length < room ? (Uint32)length : room;
    chunk -= chunk % frame_bytes;

    if (SDL_QueueAudio(device, pcm, chunk) != 0) {
      return fail_sdl("SDL_QueueAudio");
    }

    if (!*started) {
      SDL_PauseAudioDevice(device, 0);
      *started = 1;
    }

    pcm += chunk;
    length -= chunk;
  }

  return 0;
}

int main(int argc, char **argv) {
  int sample_rate;
  int channels;
  int max_latency_ms;

  if (argc != 5 || strcmp(argv[4], "packet4") != 0 ||
      parse_integer(argv[1], 8000, 192000, &sample_rate) != 0 ||
      parse_integer(argv[2], 1, 2, &channels) != 0 ||
      parse_integer(argv[3], 5, 500, &max_latency_ms) != 0) {
    fprintf(stderr,
            "usage: %s SAMPLE_RATE CHANNELS MAX_LATENCY_MS packet4\n",
            argv[0]);
    return 2;
  }

  SDL_SetMainReady();

  if (SDL_Init(SDL_INIT_AUDIO) != 0) {
    return fail_sdl("SDL_Init");
  }

  SDL_AudioSpec wanted = {0};
  SDL_AudioSpec obtained = {0};
  wanted.freq = sample_rate;
  wanted.format = AUDIO_S16LSB;
  wanted.channels = (Uint8)channels;
  wanted.samples = 256;
  wanted.callback = NULL;

  SDL_AudioDeviceID device =
      SDL_OpenAudioDevice(NULL, 0, &wanted, &obtained, 0);

  if (device == 0) {
    int result = fail_sdl("SDL_OpenAudioDevice");
    SDL_Quit();
    return result;
  }

  const size_t frame_bytes = (size_t)channels * sizeof(int16_t);
  const Uint32 max_queue_bytes =
      (Uint32)((uint64_t)sample_rate * frame_bytes * max_latency_ms / 1000);
  unsigned char buffer[READ_BUFFER_SIZE];
  int started = 0;
  int result = 0;

  for (;;) {
    unsigned char header[4];
    int header_result = read_exact(STDIN_FILENO, header, sizeof(header));

    if (header_result == 0) {
      break;
    }

    if (header_result < 0) {
      perror("beamicom audio: read");
      result = 1;
      break;
    }

    uint32_t packet_size = ((uint32_t)header[0] << 24) |
                           ((uint32_t)header[1] << 16) |
                           ((uint32_t)header[2] << 8) | (uint32_t)header[3];

    if (packet_size > MAX_PACKET_SIZE || packet_size % frame_bytes != 0) {
      fprintf(stderr, "beamicom audio: invalid packet size: %u\n", packet_size);
      result = 1;
      break;
    }

    uint32_t remaining = packet_size;

    while (remaining != 0) {
      size_t chunk = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
      int read_result = read_exact(STDIN_FILENO, buffer, chunk);

      if (read_result <= 0) {
        if (read_result < 0) {
          perror("beamicom audio: read");
        }
        result = 1;
        goto done;
      }

      if (queue_audio_bounded(device, buffer, chunk, max_queue_bytes,
                              frame_bytes, &started) != 0) {
        result = 1;
        goto done;
      }

      remaining -= (uint32_t)chunk;
    }

    const unsigned char acknowledgement[] = {0, 0, 0, 1, 1};

    if (write_exact(STDOUT_FILENO, acknowledgement,
                    sizeof(acknowledgement)) != 0) {
      if (errno != EPIPE) {
        perror("beamicom audio: write");
        result = 1;
      }
      break;
    }
  }

done:
  SDL_CloseAudioDevice(device);
  SDL_Quit();
  return result;
}
