PREFIX = $(MIX_APP_PATH)/priv/native
BUILD = $(MIX_APP_PATH)/obj
NIF = $(PREFIX)/file_dialog.so
SOURCE = c_src/file_dialog.c

CFLAGS ?= -O2 -Wall -Wextra -Werror
CFLAGS += -fPIC -std=c11 -I$(ERL_EI_INCLUDE_DIR)
LDFLAGS += -shared

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
CFLAGS += -x objective-c -Wno-deprecated-declarations
LDFLAGS += -undefined dynamic_lookup -framework Cocoa
else ifeq ($(UNAME_S),Linux)
LDFLAGS += -ldl
else
$(error Beamicom Scenic file dialogs support only macOS and Linux)
endif

.PHONY: all clean

all: $(NIF)

$(NIF): $(SOURCE)
	mkdir -p $(PREFIX) $(BUILD)
	$(CC) $(CFLAGS) $(SOURCE) $(LDFLAGS) -o $(NIF)

clean:
	$(RM) $(NIF)
