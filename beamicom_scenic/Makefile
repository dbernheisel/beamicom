PREFIX = $(MIX_APP_PATH)/priv/native
BUILD = $(MIX_APP_PATH)/obj
NIF = $(PREFIX)/file_dialog.so
SOURCE = c_src/file_dialog.c
TARGETS = $(NIF)

CFLAGS ?= -O2 -Wall -Wextra -Werror
CFLAGS += -fPIC -std=c11 -I$(ERL_EI_INCLUDE_DIR)
LDFLAGS += -shared

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
MAC_HELPER_BUNDLE = $(PREFIX)/BeamicomFileDialog.app
MAC_HELPER = $(MAC_HELPER_BUNDLE)/Contents/MacOS/BeamicomFileDialog
MAC_HELPER_SOURCE = c_src/file_dialog_macos.m
MAC_HELPER_PLIST = c_src/file_dialog_macos_info.plist
TARGETS += $(MAC_HELPER)
LDFLAGS += -undefined dynamic_lookup
else ifeq ($(UNAME_S),Linux)
LDFLAGS += -ldl
else
$(error Beamicom Scenic file dialogs support only macOS and Linux)
endif

.PHONY: all clean

all: $(TARGETS)

$(NIF): $(SOURCE) Makefile
	mkdir -p $(PREFIX) $(BUILD)
	$(CC) $(CFLAGS) $(SOURCE) $(LDFLAGS) -o $(NIF)

ifeq ($(UNAME_S),Darwin)
$(MAC_HELPER): $(MAC_HELPER_SOURCE) $(MAC_HELPER_PLIST) Makefile
	mkdir -p $(MAC_HELPER_BUNDLE)/Contents/MacOS
	cp $(MAC_HELPER_PLIST) $(MAC_HELPER_BUNDLE)/Contents/Info.plist
	$(CC) -O2 -Wall -Wextra -Werror -fobjc-arc $(MAC_HELPER_SOURCE) -framework Cocoa -o $(MAC_HELPER)
endif

clean:
	$(RM) $(NIF)
ifeq ($(UNAME_S),Darwin)
	$(RM) -r $(MAC_HELPER_BUNDLE)
endif
