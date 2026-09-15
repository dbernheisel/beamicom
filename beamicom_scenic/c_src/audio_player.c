#define SDL_MAIN_HANDLED
#include <SDL.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define READ_BUFFER_SIZE 65536

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

int main(int argc, char **argv) {
  int sample_rate;
  int channels;
  int max_latency_ms;

  if (argc != 4 || parse_integer(argv[1], 8000, 192000, &sample_rate) != 0 ||
      parse_integer(argv[2], 1, 2, &channels) != 0 ||
      parse_integer(argv[3], 5, 500, &max_latency_ms) != 0) {
    fprintf(stderr,
            "usage: %s SAMPLE_RATE CHANNELS MAX_LATENCY_MS\n",
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
  size_t carried = 0;
  int started = 0;
  int result = 0;

  for (;;) {
    ssize_t received =
        read(STDIN_FILENO, buffer + carried, sizeof(buffer) - carried);

    if (received == 0) {
      break;
    }

    if (received < 0) {
      if (errno == EINTR) {
        continue;
      }

      perror("beamicom audio: read");
      result = 1;
      break;
    }

    size_t available = carried + (size_t)received;
    size_t aligned = available - available % frame_bytes;
    size_t consumed = aligned;
    carried = available - aligned;

    if (aligned == 0) {
      continue;
    }

    unsigned char *pcm = buffer;

    if (aligned > max_queue_bytes) {
      size_t kept = max_queue_bytes - max_queue_bytes % frame_bytes;
      pcm += aligned - kept;
      aligned = kept;
    }

    Uint32 queued = SDL_GetQueuedAudioSize(device);

    if (queued + aligned > max_queue_bytes) {
      SDL_ClearQueuedAudio(device);
    }

    if (SDL_QueueAudio(device, pcm, (Uint32)aligned) != 0) {
      result = fail_sdl("SDL_QueueAudio");
      break;
    }

    if (!started) {
      SDL_PauseAudioDevice(device, 0);
      started = 1;
    }

    if (carried != 0) {
      memmove(buffer, buffer + consumed, carried);
    }
  }

  SDL_CloseAudioDevice(device);
  SDL_Quit();
  return result;
}
