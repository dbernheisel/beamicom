#include <erl_nif.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
#else
#include <dlfcn.h>
#endif

typedef struct {
  char *label;
  size_t extension_count;
  char **extensions;
} dialog_filter_t;

typedef struct {
  char *title;
  char *initial_directory;
  char *default_name;
  size_t filter_count;
  dialog_filter_t *filters;
  bool save;
  bool directory;
} dialog_request_t;

typedef enum {
  DIALOG_OK,
  DIALOG_CANCEL,
  DIALOG_ERROR,
} dialog_result_kind_t;

typedef struct {
  dialog_result_kind_t kind;
  char *value;
} dialog_result_t;

static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_nil;
static ERL_NIF_TERM atom_ok;
static ErlNifMutex *dialog_mutex;

static char *copy_bytes(const char *bytes, size_t size) {
  char *copy = enif_alloc(size + 1);

  if (copy == NULL) {
    return NULL;
  }

  memcpy(copy, bytes, size);
  copy[size] = '\0';
  return copy;
}

static bool decode_string(ErlNifEnv *env, ERL_NIF_TERM term, char **value) {
  ErlNifBinary binary;

  if (!enif_inspect_binary(env, term, &binary) ||
      memchr(binary.data, '\0', binary.size) != NULL) {
    return false;
  }

  *value = copy_bytes((const char *)binary.data, binary.size);
  return *value != NULL;
}

static bool decode_optional_string(ErlNifEnv *env, ERL_NIF_TERM term,
                                   char **value) {
  if (enif_is_identical(term, atom_nil)) {
    *value = NULL;
    return true;
  }

  return decode_string(env, term, value);
}

static void free_filter(dialog_filter_t *filter) {
  if (filter->extensions != NULL) {
    for (size_t index = 0; index < filter->extension_count; index++) {
      enif_free(filter->extensions[index]);
    }

    enif_free(filter->extensions);
  }

  if (filter->label != NULL) {
    enif_free(filter->label);
  }
}

static void free_request(dialog_request_t *request) {
  if (request->filters != NULL) {
    for (size_t index = 0; index < request->filter_count; index++) {
      free_filter(&request->filters[index]);
    }

    enif_free(request->filters);
  }

  if (request->title != NULL) {
    enif_free(request->title);
  }

  if (request->initial_directory != NULL) {
    enif_free(request->initial_directory);
  }

  if (request->default_name != NULL) {
    enif_free(request->default_name);
  }
}

static bool decode_extensions(ErlNifEnv *env, ERL_NIF_TERM list,
                              dialog_filter_t *filter) {
  unsigned int length;
  ERL_NIF_TERM head;
  ERL_NIF_TERM tail = list;

  if (!enif_get_list_length(env, list, &length) || length == 0) {
    return false;
  }

  filter->extension_count = length;
  filter->extensions = enif_alloc(sizeof(char *) * length);

  if (filter->extensions == NULL) {
    return false;
  }

  memset(filter->extensions, 0, sizeof(char *) * length);

  for (unsigned int index = 0; index < length; index++) {
    if (!enif_get_list_cell(env, tail, &head, &tail) ||
        !decode_string(env, head, &filter->extensions[index])) {
      return false;
    }
  }

  return enif_is_empty_list(env, tail);
}

static bool decode_filters(ErlNifEnv *env, ERL_NIF_TERM list,
                           dialog_request_t *request) {
  unsigned int length;
  ERL_NIF_TERM head;
  ERL_NIF_TERM tail = list;

  if (!enif_get_list_length(env, list, &length)) {
    return false;
  }

  request->filter_count = length;

  if (length == 0) {
    return true;
  }

  request->filters = enif_alloc(sizeof(dialog_filter_t) * length);

  if (request->filters == NULL) {
    return false;
  }

  memset(request->filters, 0, sizeof(dialog_filter_t) * length);

  for (unsigned int index = 0; index < length; index++) {
    const ERL_NIF_TERM *tuple;
    int arity;

    if (!enif_get_list_cell(env, tail, &head, &tail) ||
        !enif_get_tuple(env, head, &arity, &tuple) || arity != 2 ||
        !decode_string(env, tuple[0], &request->filters[index].label) ||
        !decode_extensions(env, tuple[1], &request->filters[index])) {
      return false;
    }
  }

  return enif_is_empty_list(env, tail);
}

static bool decode_request(ErlNifEnv *env, int argc,
                           const ERL_NIF_TERM argv[], bool save, bool directory,
                           dialog_request_t *request) {
  memset(request, 0, sizeof(*request));
  request->save = save;
  request->directory = directory;

  if (directory) {
    if (argc != 2 || !decode_string(env, argv[0], &request->title) ||
        !decode_optional_string(env, argv[1], &request->initial_directory)) {
      free_request(request);
      memset(request, 0, sizeof(*request));
      return false;
    }

    return true;
  }

  if (argc != (save ? 4 : 3) || !decode_string(env, argv[0], &request->title) ||
      !decode_filters(env, argv[1], request) ||
      !decode_optional_string(env, argv[2], &request->initial_directory) ||
      (save && !decode_optional_string(env, argv[3], &request->default_name))) {
    free_request(request);
    memset(request, 0, sizeof(*request));
    return false;
  }

  return true;
}

static dialog_result_t result(dialog_result_kind_t kind, const char *value) {
  dialog_result_t result_value = {.kind = kind, .value = NULL};

  if (value != NULL) {
    result_value.value = copy_bytes(value, strlen(value));

    if (result_value.value == NULL) {
      result_value.kind = DIALOG_ERROR;
      result_value.value = copy_bytes("out of memory", strlen("out of memory"));
    }
  }

  return result_value;
}

#ifdef __APPLE__

#define MAC_HELPER_EXECUTABLE_SUFFIX "/Contents/MacOS/BeamicomFileDialog"
#define MAC_HELPER_MAX_OUTPUT (1024 * 1024)
#define MAC_HELPER_TIMEOUT_SECONDS (10 * 60)
#define MAC_HELPER_WAIT_NANOSECONDS (50 * 1000 * 1000)

typedef enum {
  MAC_HELPER_EXITED,
  MAC_HELPER_WAIT_ERROR,
  MAC_HELPER_WAIT_TIMEOUT,
} mac_helper_wait_result_t;

static dialog_result_t mac_error(const char *operation, int error_number) {
  char message[512];
  snprintf(message, sizeof(message), "%s: %s", operation,
           strerror(error_number));
  return result(DIALOG_ERROR, message);
}

static bool deadline_reached(const struct timespec *deadline,
                             const struct timespec *now) {
  return now->tv_sec > deadline->tv_sec ||
         (now->tv_sec == deadline->tv_sec &&
          now->tv_nsec >= deadline->tv_nsec);
}

static mac_helper_wait_result_t wait_for_helper(pid_t pid, int *status,
                                                int *wait_error) {
  struct timespec deadline;

  if (clock_gettime(CLOCK_MONOTONIC, &deadline) == -1) {
    *wait_error = errno;
    return MAC_HELPER_WAIT_ERROR;
  }

  deadline.tv_sec += MAC_HELPER_TIMEOUT_SECONDS;

  for (;;) {
    pid_t waited = waitpid(pid, status, WNOHANG);

    if (waited == pid) {
      return MAC_HELPER_EXITED;
    }

    if (waited == -1 && errno != EINTR) {
      *wait_error = errno;
      return MAC_HELPER_WAIT_ERROR;
    }

    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) == -1) {
      *wait_error = errno;
      return MAC_HELPER_WAIT_ERROR;
    }

    if (deadline_reached(&deadline, &now)) {
      return MAC_HELPER_WAIT_TIMEOUT;
    }

    struct timespec pause = {
        .tv_sec = 0,
        .tv_nsec = MAC_HELPER_WAIT_NANOSECONDS,
    };

    while (nanosleep(&pause, &pause) == -1) {
      if (errno != EINTR) {
        *wait_error = errno;
        return MAC_HELPER_WAIT_ERROR;
      }
    }
  }
}

static void terminate_and_reap_helper(pid_t pid) {
  int status;

  if (kill(pid, SIGKILL) == -1 && errno != ESRCH) {
    return;
  }

  while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {
  }
}

static char *mac_helper_executable_path(const char *helper_bundle_path) {
  size_t bundle_length = strlen(helper_bundle_path);
  size_t suffix_length = strlen(MAC_HELPER_EXECUTABLE_SUFFIX);

  if (bundle_length > SIZE_MAX - suffix_length - 1) {
    return NULL;
  }

  char *executable_path = enif_alloc(bundle_length + suffix_length + 1);

  if (executable_path == NULL) {
    return NULL;
  }

  memcpy(executable_path, helper_bundle_path, bundle_length);
  memcpy(executable_path + bundle_length, MAC_HELPER_EXECUTABLE_SUFFIX,
         suffix_length + 1);
  return executable_path;
}

static bool read_helper_output(int descriptor, char **output, size_t *length,
                               int *read_error) {
  size_t capacity = 4096;
  char *buffer = enif_alloc(capacity);

  if (buffer == NULL) {
    *read_error = ENOMEM;
    return false;
  }

  *length = 0;

  for (;;) {
    if (*length == capacity) {
      if (capacity >= MAC_HELPER_MAX_OUTPUT) {
        enif_free(buffer);
        *read_error = EOVERFLOW;
        return false;
      }

      size_t new_capacity = capacity * 2;
      char *larger_buffer = enif_realloc(buffer, new_capacity);

      if (larger_buffer == NULL) {
        enif_free(buffer);
        *read_error = ENOMEM;
        return false;
      }

      buffer = larger_buffer;
      capacity = new_capacity;
    }

    ssize_t bytes_read = read(descriptor, buffer + *length, capacity - *length);

    if (bytes_read > 0) {
      *length += (size_t)bytes_read;
    } else if (bytes_read == 0) {
      break;
    } else if (errno != EINTR) {
      enif_free(buffer);
      *read_error = errno;
      return false;
    }
  }

  if (*length == capacity) {
    char *larger_buffer = enif_realloc(buffer, capacity + 1);

    if (larger_buffer == NULL) {
      enif_free(buffer);
      *read_error = ENOMEM;
      return false;
    }

    buffer = larger_buffer;
  }

  buffer[*length] = '\0';
  *output = buffer;
  return true;
}

static dialog_result_t decode_helper_output(const char *output, size_t length) {
  if (length == 0) {
    return result(DIALOG_ERROR, "macOS file dialog helper returned no result");
  }

  switch (output[0]) {
  case 'O':
    if (length == 1) {
      return result(DIALOG_ERROR,
                    "macOS file dialog helper returned an empty path");
    }
    return result(DIALOG_OK, output + 1);
  case 'C':
    return result(DIALOG_CANCEL, NULL);
  case 'E':
    return result(DIALOG_ERROR,
                  length == 1 ? "macOS file dialog failed" : output + 1);
  default:
    return result(DIALOG_ERROR,
                  "macOS file dialog helper returned an invalid result");
  }
}

static dialog_result_t run_mac_helper(const dialog_request_t *request,
                                      const char *helper_bundle_path) {
  char *helper_executable_path =
      mac_helper_executable_path(helper_bundle_path);

  if (helper_executable_path == NULL) {
    return result(DIALOG_ERROR, "out of memory");
  }

  if (access(helper_executable_path, X_OK) != 0) {
    int access_error = errno;
    enif_free(helper_executable_path);
    return mac_error("could not launch macOS file dialog helper", access_error);
  }

  size_t extension_count = 0;

  for (size_t filter_index = 0; filter_index < request->filter_count;
       filter_index++) {
    extension_count += request->filters[filter_index].extension_count;
  }

  char result_path[] = "/tmp/beamicom-file-dialog.XXXXXX";
  int result_descriptor = mkstemp(result_path);

  if (result_descriptor == -1) {
    enif_free(helper_executable_path);
    return mac_error("could not create macOS file dialog result", errno);
  }

  close(result_descriptor);

  char **arguments = enif_alloc(sizeof(char *) * (extension_count + 7));

  if (arguments == NULL) {
    enif_free(helper_executable_path);
    unlink(result_path);
    return result(DIALOG_ERROR, "out of memory");
  }

  size_t argument_index = 0;
  arguments[argument_index++] = helper_executable_path;
  arguments[argument_index++] = result_path;
  arguments[argument_index++] =
      request->directory ? "directory" : (request->save ? "save" : "open");
  arguments[argument_index++] = request->title;
  arguments[argument_index++] =
      request->initial_directory == NULL ? "" : request->initial_directory;
  arguments[argument_index++] =
      request->default_name == NULL ? "" : request->default_name;

  for (size_t filter_index = 0; filter_index < request->filter_count;
       filter_index++) {
    const dialog_filter_t *filter = &request->filters[filter_index];

    for (size_t extension_index = 0;
         extension_index < filter->extension_count; extension_index++) {
      arguments[argument_index++] = filter->extensions[extension_index];
    }
  }

  arguments[argument_index] = NULL;

  pid_t pid;
  int spawn_error = posix_spawn(&pid, helper_executable_path, NULL, NULL,
                                arguments, environ);
  enif_free(arguments);
  enif_free(helper_executable_path);

  if (spawn_error != 0) {
    unlink(result_path);
    return mac_error("could not launch macOS file dialog", spawn_error);
  }

  int status;
  int wait_error = 0;
  mac_helper_wait_result_t wait_result =
      wait_for_helper(pid, &status, &wait_error);

  if (wait_result == MAC_HELPER_WAIT_TIMEOUT) {
    terminate_and_reap_helper(pid);
    unlink(result_path);
    return result(DIALOG_ERROR, "macOS file dialog helper timed out");
  }

  if (wait_result == MAC_HELPER_WAIT_ERROR) {
    terminate_and_reap_helper(pid);
    unlink(result_path);
    return mac_error("could not wait for macOS file dialog", wait_error);
  }

  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    unlink(result_path);
    return result(DIALOG_ERROR,
                  "macOS file dialog helper exited unexpectedly");
  }

  result_descriptor = open(result_path, O_RDONLY);

  if (result_descriptor == -1) {
    int open_error = errno;
    unlink(result_path);
    return mac_error("could not open macOS file dialog result", open_error);
  }

  char *output = NULL;
  size_t output_length = 0;
  int read_error = 0;
  bool output_read = read_helper_output(result_descriptor, &output,
                                        &output_length, &read_error);
  close(result_descriptor);
  unlink(result_path);

  if (!output_read) {
    return mac_error("could not read macOS file dialog result", read_error);
  }

  dialog_result_t dialog_result =
      decode_helper_output(output, output_length);
  enif_free(output);
  return dialog_result;
}

static dialog_result_t platform_show(const dialog_request_t *request,
                                     const char *helper_path) {
  return run_mac_helper(request, helper_path);
}

#else

typedef struct {
  void *handle;
  int (*init_check)(int *, char ***);
  void *(*native_new)(const char *, void *, int, const char *, const char *);
  int (*native_run)(void *);
  void *(*filter_new)(void);
  void (*filter_set_name)(void *, const char *);
  void (*filter_add_pattern)(void *, const char *);
  void (*chooser_add_filter)(void *, void *);
  int (*chooser_set_folder)(void *, const char *);
  void (*chooser_set_name)(void *, const char *);
  void (*chooser_set_overwrite)(void *, int);
  char *(*chooser_get_filename)(void *);
  char *(*filename_from_utf8)(const char *, long, size_t *, size_t *, void **);
  char *(*filename_to_utf8)(const char *, long, size_t *, size_t *, void **);
  void (*object_unref)(void *);
  void (*free_memory)(void *);
} gtk_api_t;

static gtk_api_t gtk;

#define LOAD_GTK_SYMBOL(field, symbol)                                         \
  do {                                                                         \
    *(void **)(&gtk.field) = dlsym(gtk.handle, symbol);                         \
    if (gtk.field == NULL) {                                                    \
      dlclose(gtk.handle);                                                      \
      memset(&gtk, 0, sizeof(gtk));                                             \
      return false;                                                             \
    }                                                                           \
  } while (0)

static bool load_gtk(void) {
  if (gtk.handle != NULL) {
    return true;
  }

  gtk.handle = dlopen("libgtk-3.so.0", RTLD_NOW | RTLD_LOCAL);

  if (gtk.handle == NULL) {
    return false;
  }

  LOAD_GTK_SYMBOL(init_check, "gtk_init_check");
  LOAD_GTK_SYMBOL(native_new, "gtk_file_chooser_native_new");
  LOAD_GTK_SYMBOL(native_run, "gtk_native_dialog_run");
  LOAD_GTK_SYMBOL(filter_new, "gtk_file_filter_new");
  LOAD_GTK_SYMBOL(filter_set_name, "gtk_file_filter_set_name");
  LOAD_GTK_SYMBOL(filter_add_pattern, "gtk_file_filter_add_pattern");
  LOAD_GTK_SYMBOL(chooser_add_filter, "gtk_file_chooser_add_filter");
  LOAD_GTK_SYMBOL(chooser_set_folder, "gtk_file_chooser_set_current_folder");
  LOAD_GTK_SYMBOL(chooser_set_name, "gtk_file_chooser_set_current_name");
  LOAD_GTK_SYMBOL(chooser_set_overwrite,
                  "gtk_file_chooser_set_do_overwrite_confirmation");
  LOAD_GTK_SYMBOL(chooser_get_filename, "gtk_file_chooser_get_filename");
  LOAD_GTK_SYMBOL(filename_from_utf8, "g_filename_from_utf8");
  LOAD_GTK_SYMBOL(filename_to_utf8, "g_filename_to_utf8");
  LOAD_GTK_SYMBOL(object_unref, "g_object_unref");
  LOAD_GTK_SYMBOL(free_memory, "g_free");
  return true;
}

static bool add_gtk_filters(void *dialog, const dialog_request_t *request) {
  for (size_t filter_index = 0; filter_index < request->filter_count;
       filter_index++) {
    const dialog_filter_t *source = &request->filters[filter_index];
    void *filter = gtk.filter_new();

    if (filter == NULL) {
      return false;
    }

    gtk.filter_set_name(filter, source->label);

    for (size_t extension_index = 0;
         extension_index < source->extension_count; extension_index++) {
      const char *extension = source->extensions[extension_index];
      size_t pattern_size = strlen(extension) + 3;
      char *pattern = enif_alloc(pattern_size);

      if (pattern == NULL) {
        gtk.object_unref(filter);
        return false;
      }

      pattern[0] = '*';
      pattern[1] = '.';
      memcpy(pattern + 2, extension, strlen(extension) + 1);
      gtk.filter_add_pattern(filter, pattern);
      enif_free(pattern);
    }

    gtk.chooser_add_filter(dialog, filter);
    gtk.object_unref(filter);
  }

  return true;
}

static dialog_result_t platform_show(const dialog_request_t *request,
                                     const char *helper_path) {
  (void)helper_path;

  if (!load_gtk()) {
    return result(DIALOG_ERROR, "GTK 3 is unavailable");
  }

  if (!gtk.init_check(NULL, NULL)) {
    return result(DIALOG_ERROR, "GTK could not connect to a display");
  }

  int action = request->directory ? 2 : (request->save ? 1 : 0);
  const char *accept_label =
      request->directory ? "Select" : (request->save ? "Save" : "Open");
  void *dialog = gtk.native_new(request->title, NULL, action, accept_label,
                                "Cancel");

  if (dialog == NULL) {
    return result(DIALOG_ERROR, "could not create GTK file selector");
  }

  if (!add_gtk_filters(dialog, request)) {
    gtk.object_unref(dialog);
    return result(DIALOG_ERROR, "could not create GTK file filters");
  }

  if (request->initial_directory != NULL) {
    char *directory =
        gtk.filename_from_utf8(request->initial_directory, -1, NULL, NULL, NULL);

    if (directory != NULL) {
      gtk.chooser_set_folder(dialog, directory);
      gtk.free_memory(directory);
    }
  }

  if (request->save) {
    gtk.chooser_set_overwrite(dialog, 1);

    if (request->default_name != NULL) {
      gtk.chooser_set_name(dialog, request->default_name);
    }
  }

  int response = gtk.native_run(dialog);
  dialog_result_t dialog_result = result(DIALOG_CANCEL, NULL);

  if (response == -3 || response == -5) {
    char *filename = gtk.chooser_get_filename(dialog);

    if (filename != NULL) {
      char *utf8 = gtk.filename_to_utf8(filename, -1, NULL, NULL, NULL);

      if (utf8 != NULL) {
        dialog_result = result(DIALOG_OK, utf8);
        gtk.free_memory(utf8);
      } else {
        dialog_result = result(DIALOG_ERROR,
                               "selected path is not valid UTF-8");
      }

      gtk.free_memory(filename);
    }
  }

  gtk.object_unref(dialog);
  return dialog_result;
}

#endif

static ERL_NIF_TERM encode_result(ErlNifEnv *env,
                                  dialog_result_t dialog_result) {
  ERL_NIF_TERM encoded;

  switch (dialog_result.kind) {
  case DIALOG_OK: {
    size_t size = strlen(dialog_result.value);
    unsigned char *bytes = enif_make_new_binary(env, size, &encoded);
    memcpy(bytes, dialog_result.value, size);
    encoded = enif_make_tuple2(env, atom_ok, encoded);
    break;
  }
  case DIALOG_CANCEL:
    encoded = enif_make_tuple2(env, atom_ok, atom_nil);
    break;
  case DIALOG_ERROR: {
    const char *message =
        dialog_result.value == NULL ? "native file dialog failed"
                                    : dialog_result.value;
    size_t size = strlen(message);
    unsigned char *bytes = enif_make_new_binary(env, size, &encoded);
    memcpy(bytes, message, size);
    encoded = enif_make_tuple2(env, atom_error, encoded);
    break;
  }
  }

  if (dialog_result.value != NULL) {
    enif_free(dialog_result.value);
  }

  return encoded;
}

static ERL_NIF_TERM show_dialog(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[], bool save,
                                bool directory) {
  dialog_request_t request;
  char *helper_path = NULL;
  memset(&request, 0, sizeof(request));

  if (argc < 1 ||
      !decode_request(env, argc - 1, argv, save, directory, &request) ||
      !decode_string(env, argv[argc - 1], &helper_path)) {
    free_request(&request);
    return enif_make_badarg(env);
  }

  enif_mutex_lock(dialog_mutex);
  dialog_result_t dialog_result = platform_show(&request, helper_path);
  enif_mutex_unlock(dialog_mutex);
  enif_free(helper_path);
  free_request(&request);
  return encode_result(env, dialog_result);
}

static ERL_NIF_TERM mac_open_nif(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  return show_dialog(env, argc, argv, false, false);
}

static ERL_NIF_TERM mac_save_nif(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  return show_dialog(env, argc, argv, true, false);
}

static ERL_NIF_TERM mac_directory_nif(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
  return show_dialog(env, argc, argv, false, true);
}

static int load(ErlNifEnv *env, void **private_data, ERL_NIF_TERM load_info) {
  (void)private_data;
  (void)load_info;
  atom_error = enif_make_atom(env, "error");
  atom_nil = enif_make_atom(env, "nil");
  atom_ok = enif_make_atom(env, "ok");
  dialog_mutex = enif_mutex_create("beamicom_file_dialog");
  return dialog_mutex == NULL ? 1 : 0;
}

static void unload(ErlNifEnv *env, void *private_data) {
  (void)env;
  (void)private_data;

#ifndef __APPLE__
  if (gtk.handle != NULL) {
    dlclose(gtk.handle);
  }
#endif

  if (dialog_mutex != NULL) {
    enif_mutex_destroy(dialog_mutex);
  }
}

static ErlNifFunc nif_functions[] = {
    {"mac_open", 4, mac_open_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"mac_save", 5, mac_save_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"mac_directory", 3, mac_directory_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.Beamicom.Scenic.FileDialog.Native, nif_functions, load,
             NULL, NULL, unload)
