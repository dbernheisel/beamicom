#define SDL_MAIN_HANDLED
#include <SDL.h>

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define MAX_CONTROLLERS 16
#define MAX_NAME_BYTES 240
#define STICK_DEAD_ZONE 16384

#define MESSAGE_CONNECTED 1
#define MESSAGE_STATE 2
#define MESSAGE_DISCONNECTED 3

#define BUTTON_UP (1u << 0)
#define BUTTON_DOWN (1u << 1)
#define BUTTON_LEFT (1u << 2)
#define BUTTON_RIGHT (1u << 3)
#define BUTTON_A (1u << 4)
#define BUTTON_B (1u << 5)
#define BUTTON_X (1u << 6)
#define BUTTON_Y (1u << 7)
#define BUTTON_L (1u << 8)
#define BUTTON_R (1u << 9)
#define BUTTON_SELECT (1u << 10)
#define BUTTON_START (1u << 11)

typedef struct {
  SDL_GameController *controller;
  SDL_JoystickID instance_id;
  uint16_t digital_buttons;
  uint16_t buttons;
  Sint16 left_x;
  Sint16 left_y;
} controller_slot_t;

static controller_slot_t controllers[MAX_CONTROLLERS];

static void put_u16(uint8_t *destination, uint16_t value) {
  destination[0] = (uint8_t)(value >> 8);
  destination[1] = (uint8_t)value;
}

static void put_u32(uint8_t *destination, uint32_t value) {
  destination[0] = (uint8_t)(value >> 24);
  destination[1] = (uint8_t)(value >> 16);
  destination[2] = (uint8_t)(value >> 8);
  destination[3] = (uint8_t)value;
}

static int write_all(const uint8_t *bytes, size_t length) {
  while (length != 0) {
    ssize_t written = write(STDOUT_FILENO, bytes, length);

    if (written < 0 && errno == EINTR) {
      continue;
    }

    if (written <= 0) {
      return -1;
    }

    bytes += written;
    length -= (size_t)written;
  }

  return 0;
}

static int send_packet(const uint8_t *payload, uint16_t length) {
  uint8_t header[2];
  put_u16(header, length);

  return write_all(header, sizeof(header)) == 0 &&
                 write_all(payload, length) == 0
             ? 0
             : -1;
}

static int send_connected(SDL_JoystickID instance_id, const char *name) {
  uint8_t payload[1 + 4 + MAX_NAME_BYTES];
  size_t name_length = name == NULL ? 0 : strlen(name);

  if (name_length > MAX_NAME_BYTES) {
    name_length = MAX_NAME_BYTES;
  }

  payload[0] = MESSAGE_CONNECTED;
  put_u32(payload + 1, (uint32_t)instance_id);

  if (name_length != 0) {
    memcpy(payload + 5, name, name_length);
  }

  return send_packet(payload, (uint16_t)(5 + name_length));
}

static int send_state(SDL_JoystickID instance_id, uint16_t buttons) {
  uint8_t payload[7];
  payload[0] = MESSAGE_STATE;
  put_u32(payload + 1, (uint32_t)instance_id);
  put_u16(payload + 5, buttons);
  return send_packet(payload, sizeof(payload));
}

static int send_disconnected(SDL_JoystickID instance_id) {
  uint8_t payload[5];
  payload[0] = MESSAGE_DISCONNECTED;
  put_u32(payload + 1, (uint32_t)instance_id);
  return send_packet(payload, sizeof(payload));
}

static controller_slot_t *find_controller(SDL_JoystickID instance_id) {
  for (size_t index = 0; index < MAX_CONTROLLERS; index++) {
    if (controllers[index].controller != NULL &&
        controllers[index].instance_id == instance_id) {
      return &controllers[index];
    }
  }

  return NULL;
}

static controller_slot_t *available_slot(void) {
  for (size_t index = 0; index < MAX_CONTROLLERS; index++) {
    if (controllers[index].controller == NULL) {
      return &controllers[index];
    }
  }

  return NULL;
}

static uint16_t controller_button_mask(SDL_GameControllerButton button) {
  switch (button) {
  case SDL_CONTROLLER_BUTTON_DPAD_UP:
    return BUTTON_UP;
  case SDL_CONTROLLER_BUTTON_DPAD_DOWN:
    return BUTTON_DOWN;
  case SDL_CONTROLLER_BUTTON_DPAD_LEFT:
    return BUTTON_LEFT;
  case SDL_CONTROLLER_BUTTON_DPAD_RIGHT:
    return BUTTON_RIGHT;
  case SDL_CONTROLLER_BUTTON_A:
    return BUTTON_A;
  case SDL_CONTROLLER_BUTTON_B:
    return BUTTON_B;
  case SDL_CONTROLLER_BUTTON_X:
    return BUTTON_X;
  case SDL_CONTROLLER_BUTTON_Y:
    return BUTTON_Y;
  case SDL_CONTROLLER_BUTTON_LEFTSHOULDER:
    return BUTTON_L;
  case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER:
    return BUTTON_R;
  case SDL_CONTROLLER_BUTTON_BACK:
    return BUTTON_SELECT;
  case SDL_CONTROLLER_BUTTON_START:
    return BUTTON_START;
  default:
    return 0;
  }
}

static uint16_t digital_buttons(SDL_GameController *controller) {
  uint16_t buttons = 0;

  for (int button = SDL_CONTROLLER_BUTTON_A;
       button < SDL_CONTROLLER_BUTTON_MAX; button++) {
    if (SDL_GameControllerGetButton(controller,
                                    (SDL_GameControllerButton)button)) {
      buttons |= controller_button_mask((SDL_GameControllerButton)button);
    }
  }

  return buttons;
}

static uint16_t controller_buttons(const controller_slot_t *slot) {
  uint16_t buttons = slot->digital_buttons;

  if (slot->left_y < -STICK_DEAD_ZONE) {
    buttons |= BUTTON_UP;
  }

  if (slot->left_y > STICK_DEAD_ZONE) {
    buttons |= BUTTON_DOWN;
  }

  if (slot->left_x < -STICK_DEAD_ZONE) {
    buttons |= BUTTON_LEFT;
  }

  if (slot->left_x > STICK_DEAD_ZONE) {
    buttons |= BUTTON_RIGHT;
  }

  return buttons;
}

static int publish_controller(controller_slot_t *slot, int force) {
  uint16_t buttons = controller_buttons(slot);

  if (force || buttons != slot->buttons) {
    slot->buttons = buttons;
    return send_state(slot->instance_id, buttons);
  }

  return 0;
}

static int refresh_controller(controller_slot_t *slot, int force) {
  slot->digital_buttons = digital_buttons(slot->controller);
  slot->left_x =
      SDL_GameControllerGetAxis(slot->controller, SDL_CONTROLLER_AXIS_LEFTX);
  slot->left_y =
      SDL_GameControllerGetAxis(slot->controller, SDL_CONTROLLER_AXIS_LEFTY);
  return publish_controller(slot, force);
}

static int refresh_all_controllers(void) {
  for (size_t index = 0; index < MAX_CONTROLLERS; index++) {
    if (controllers[index].controller != NULL &&
        refresh_controller(&controllers[index], 0) != 0) {
      return -1;
    }
  }

  return 0;
}

static int open_controller(int device_index) {
  if (!SDL_IsGameController(device_index)) {
    return 0;
  }

  SDL_GameController *controller = SDL_GameControllerOpen(device_index);

  if (controller == NULL) {
    fprintf(stderr, "beamicom gamepad: SDL_GameControllerOpen: %s\n",
            SDL_GetError());
    return 0;
  }

  SDL_Joystick *joystick = SDL_GameControllerGetJoystick(controller);
  SDL_JoystickID instance_id = SDL_JoystickInstanceID(joystick);

  if (instance_id < 0 || find_controller(instance_id) != NULL) {
    SDL_GameControllerClose(controller);
    return 0;
  }

  controller_slot_t *slot = available_slot();

  if (slot == NULL) {
    SDL_GameControllerClose(controller);
    return 0;
  }

  slot->controller = controller;
  slot->instance_id = instance_id;
  slot->buttons = 0;

  if (send_connected(instance_id, SDL_GameControllerName(controller)) != 0 ||
      refresh_controller(slot, 1) != 0) {
    return -1;
  }

  return 0;
}

static int close_controller(SDL_JoystickID instance_id) {
  controller_slot_t *slot = find_controller(instance_id);

  if (slot == NULL) {
    return 0;
  }

  if (send_disconnected(instance_id) != 0) {
    return -1;
  }

  SDL_GameControllerClose(slot->controller);
  memset(slot, 0, sizeof(*slot));
  return 0;
}

static int handle_event(const SDL_Event *event) {
  controller_slot_t *slot;
  uint16_t button;

  switch (event->type) {
  case SDL_CONTROLLERDEVICEADDED:
    return open_controller(event->cdevice.which);

  case SDL_CONTROLLERDEVICEREMOVED:
    return close_controller(event->cdevice.which);

  case SDL_CONTROLLERDEVICEREMAPPED:
    slot = find_controller(event->cdevice.which);
    return slot == NULL ? 0 : refresh_controller(slot, 1);

  case SDL_CONTROLLERBUTTONDOWN:
  case SDL_CONTROLLERBUTTONUP:
    slot = find_controller(event->cbutton.which);
    button = controller_button_mask(
        (SDL_GameControllerButton)event->cbutton.button);

    if (slot == NULL || button == 0) {
      return 0;
    }

    if (event->cbutton.state == SDL_PRESSED) {
      slot->digital_buttons |= button;
    } else {
      slot->digital_buttons &= (uint16_t)~button;
    }

    return publish_controller(slot, 0);

  case SDL_CONTROLLERAXISMOTION:
    slot = find_controller(event->caxis.which);

    if (slot == NULL) {
      return 0;
    }

    if (event->caxis.axis == SDL_CONTROLLER_AXIS_LEFTX) {
      slot->left_x = event->caxis.value;
    } else if (event->caxis.axis == SDL_CONTROLLER_AXIS_LEFTY) {
      slot->left_y = event->caxis.value;
    } else {
      return 0;
    }

    return publish_controller(slot, 0);

  default:
    return 0;
  }
}

static int parent_connected(void) {
  struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
  int result = poll(&input, 1, 0);

  if (result < 0 && errno == EINTR) {
    return 1;
  }

  return result >= 0 &&
         (input.revents & (POLLHUP | POLLERR | POLLNVAL)) == 0;
}

static void close_all_controllers(void) {
  for (size_t index = 0; index < MAX_CONTROLLERS; index++) {
    if (controllers[index].controller != NULL) {
      SDL_GameControllerClose(controllers[index].controller);
    }
  }
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  SDL_SetMainReady();
  SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");

  if (SDL_Init(SDL_INIT_GAMECONTROLLER | SDL_INIT_JOYSTICK | SDL_INIT_EVENTS) !=
      0) {
    fprintf(stderr, "beamicom gamepad: SDL_Init: %s\n", SDL_GetError());
    return 1;
  }

  int joystick_count = SDL_NumJoysticks();

  for (int index = 0; index < joystick_count; index++) {
    if (open_controller(index) != 0) {
      close_all_controllers();
      SDL_Quit();
      return 1;
    }
  }

  int result = 0;

  while (parent_connected()) {
    SDL_Event event;

    if (SDL_WaitEventTimeout(&event, 8)) {
      if (handle_event(&event) != 0) {
        result = 1;
        break;
      }

      while (SDL_PollEvent(&event)) {
        if (handle_event(&event) != 0) {
          result = 1;
          break;
        }
      }
    }

    if (result != 0) {
      break;
    }

    if (refresh_all_controllers() != 0) {
      result = 1;
      break;
    }
  }

  close_all_controllers();
  SDL_Quit();
  return result;
}
