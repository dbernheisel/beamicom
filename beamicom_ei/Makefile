PREFIX = $(MIX_APP_PATH)/priv/native
GAMEPAD_INPUT = $(PREFIX)/gamepad_input
GAMEPAD_SOURCE = c_src/gamepad_input.c
SDL_CFLAGS := $(shell (pkg-config --cflags sdl2 || sdl2-config --cflags) 2>/dev/null)
SDL_LIBS := $(shell (pkg-config --libs sdl2 || sdl2-config --libs) 2>/dev/null)
TARGETS =

ifneq ($(strip $(SDL_LIBS)),)
TARGETS += $(GAMEPAD_INPUT)
endif

.PHONY: all clean

all: $(TARGETS)

$(GAMEPAD_INPUT): $(GAMEPAD_SOURCE) Makefile
	mkdir -p $(PREFIX)
	$(CC) -O2 -Wall -Wextra -Werror -std=c11 $(SDL_CFLAGS) $(GAMEPAD_SOURCE) $(SDL_LIBS) -o $(GAMEPAD_INPUT)

clean:
	$(RM) $(GAMEPAD_INPUT)
