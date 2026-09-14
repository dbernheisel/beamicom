#import <Cocoa/Cocoa.h>

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int result_descriptor = -1;

static bool write_all(const void *bytes, size_t length) {
  const unsigned char *cursor = bytes;

  while (length > 0) {
    ssize_t written = write(result_descriptor, cursor, length);

    if (written > 0) {
      cursor += written;
      length -= (size_t)written;
    } else if (written == 0) {
      return false;
    } else if (written < 0 && errno != EINTR) {
      return false;
    }
  }

  return true;
}

static bool emit_result(char kind, NSString *value) {
  if (!write_all(&kind, 1)) {
    return false;
  }

  if (value == nil) {
    return true;
  }

  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  return data != nil && write_all(data.bytes, data.length);
}

static NSString *decode_argument(const char *argument) {
  return [NSString stringWithUTF8String:argument];
}

static NSArray<NSString *> *decode_extensions(int argc, const char *argv[]) {
  NSMutableArray<NSString *> *extensions = [NSMutableArray array];

  for (int index = 5; index < argc; index++) {
    NSString *extension = decode_argument(argv[index]);

    if (extension == nil) {
      return nil;
    }

    [extensions addObject:extension];
  }

  return extensions;
}

static NSSavePanel *create_panel(NSString *mode) {
  if ([mode isEqualToString:@"save"]) {
    return [NSSavePanel savePanel];
  }

  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseDirectories = [mode isEqualToString:@"directory"];
  panel.canChooseFiles = !panel.canChooseDirectories;
  panel.allowsMultipleSelection = NO;
  return panel;
}

static void activate_panel(NSSavePanel *panel) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  [[NSRunningApplication currentApplication]
      activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop

  [panel makeKeyAndOrderFront:nil];
  [panel orderFrontRegardless];
}

static bool run_dialog(int argc, const char *argv[]) {
  if (argc < 5) {
    return emit_result('E', @"invalid macOS file dialog arguments");
  }

  NSString *mode = decode_argument(argv[1]);
  NSString *title = decode_argument(argv[2]);
  NSString *initial_directory = decode_argument(argv[3]);
  NSString *default_name = decode_argument(argv[4]);
  NSArray<NSString *> *extensions = decode_extensions(argc, argv);

  if (mode == nil || title == nil || initial_directory == nil ||
      default_name == nil || extensions == nil) {
    return emit_result('E', @"macOS file dialog arguments are not valid UTF-8");
  }

  if (![mode isEqualToString:@"open"] && ![mode isEqualToString:@"save"] &&
      ![mode isEqualToString:@"directory"]) {
    return emit_result('E', @"invalid macOS file dialog mode");
  }

  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [NSApp finishLaunching];

  NSSavePanel *panel = create_panel(mode);
  panel.title = title;

  if (initial_directory.length > 0) {
    panel.directoryURL =
        [NSURL fileURLWithPath:initial_directory isDirectory:YES];
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (![mode isEqualToString:@"directory"] && extensions.count > 0) {
    panel.allowedFileTypes = extensions;
  }
#pragma clang diagnostic pop

  if ([mode isEqualToString:@"save"] && default_name.length > 0) {
    panel.nameFieldStringValue = default_name;
  }

  activate_panel(panel);
  NSModalResponse response = [panel runModal];

  if (response == NSModalResponseOK && panel.URL.path != nil) {
    return emit_result('O', panel.URL.path);
  }

  return emit_result('C', nil);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      return EXIT_FAILURE;
    }

    result_descriptor = open(argv[1], O_WRONLY | O_TRUNC);

    if (result_descriptor == -1) {
      return EXIT_FAILURE;
    }

    argc--;
    argv++;

    int status;

    @try {
      status = run_dialog(argc, argv) ? EXIT_SUCCESS : EXIT_FAILURE;
    } @catch (NSException *exception) {
      NSString *message = exception.reason ?: @"macOS file dialog failed";
      status = emit_result('E', message) ? EXIT_SUCCESS : EXIT_FAILURE;
    }

    close(result_descriptor);
    return status;
  }
}
