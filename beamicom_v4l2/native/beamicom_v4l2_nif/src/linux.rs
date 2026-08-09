use crate::pixel::{self, Channel, Layout};
use std::ffi::CString;
use std::fs::File;
use std::io::{self, Read, Write};
use std::mem::size_of;
use std::os::fd::{FromRawFd, RawFd};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const FBIOGET_VSCREENINFO: libc::Ioctl = 0x4600;
const FBIOGET_FSCREENINFO: libc::Ioctl = 0x4602;
const FB_VISUAL_TRUECOLOR: u32 = 2;
const V4L2_BUF_TYPE_VIDEO_OUTPUT: u32 = 2;
const V4L2_FIELD_NONE: u32 = 1;
const V4L2_COLORSPACE_SMPTE170M: u32 = 3;
const V4L2_CAP_VIDEO_OUTPUT: u32 = 0x0000_0002;
const V4L2_CAP_READWRITE: u32 = 0x0100_0000;
const V4L2_CAP_DEVICE_CAPS: u32 = 0x8000_0000;
const V4L2_PIX_FMT_YUYV: u32 = u32::from_le_bytes(*b"YUYV");
const EV_KEY: u8 = 0x01;
const KEY_MAX: usize = 0x2ff;
const KEYBOARD_KEYS: [usize; 8] = [16, 44, 45, 103, 105, 106, 108, 57];

const IOC_WRITE: u64 = 1;
const IOC_READ: u64 = 2;
const fn ioc(direction: u64, kind: u8, number: u8, size: usize) -> libc::Ioctl {
    ((direction << 30) | ((size as u64) << 16) | ((kind as u64) << 8) | number as u64)
        as libc::Ioctl
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct FbBitfield {
    offset: u32,
    length: u32,
    msb_right: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct FbVarScreeninfo {
    xres: u32,
    yres: u32,
    xres_virtual: u32,
    yres_virtual: u32,
    xoffset: u32,
    yoffset: u32,
    bits_per_pixel: u32,
    grayscale: u32,
    red: FbBitfield,
    green: FbBitfield,
    blue: FbBitfield,
    transp: FbBitfield,
    nonstd: u32,
    activate: u32,
    height: u32,
    width: u32,
    accel_flags: u32,
    pixclock: u32,
    left_margin: u32,
    right_margin: u32,
    upper_margin: u32,
    lower_margin: u32,
    hsync_len: u32,
    vsync_len: u32,
    sync: u32,
    vmode: u32,
    rotate: u32,
    colorspace: u32,
    reserved: [u32; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct FbFixScreeninfo {
    id: [u8; 16],
    smem_start: libc::c_ulong,
    smem_len: u32,
    type_: u32,
    type_aux: u32,
    visual: u32,
    xpanstep: u16,
    ypanstep: u16,
    ywrapstep: u16,
    line_length: u32,
    mmio_start: libc::c_ulong,
    mmio_len: u32,
    accel: u32,
    capabilities: u16,
    reserved: [u16; 2],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct V4l2Capability {
    driver: [u8; 16],
    card: [u8; 32],
    bus_info: [u8; 32],
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [u32; 3],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct V4l2PixFormat {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    private: u32,
    flags: u32,
    ycbcr_enc: u32,
    quantization: u32,
    xfer_func: u32,
}

#[repr(C)]
union V4l2FormatData {
    pix: V4l2PixFormat,
    raw: [u8; 200],
    _align: usize,
}

#[repr(C)]
struct V4l2Format {
    type_: u32,
    fmt: V4l2FormatData,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct V4l2Fract {
    numerator: u32,
    denominator: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct V4l2OutputParm {
    capability: u32,
    outputmode: u32,
    timeperframe: V4l2Fract,
    extendedmode: u32,
    writebuffers: u32,
    reserved: [u32; 4],
}

#[repr(C)]
union V4l2StreamParmData {
    output: V4l2OutputParm,
    raw: [u8; 200],
}

#[repr(C)]
struct V4l2StreamParm {
    type_: u32,
    parm: V4l2StreamParmData,
}

const VIDIOC_QUERYCAP: libc::Ioctl = ioc(IOC_READ, b'V', 0, size_of::<V4l2Capability>());
const VIDIOC_S_FMT: libc::Ioctl = ioc(IOC_READ | IOC_WRITE, b'V', 5, size_of::<V4l2Format>());
const VIDIOC_S_PARM: libc::Ioctl = ioc(IOC_READ | IOC_WRITE, b'V', 22, size_of::<V4l2StreamParm>());
const BITS_PER_LONG: usize = libc::c_ulong::BITS as usize;
const KEY_WORDS: usize = (KEY_MAX + 1).div_ceil(BITS_PER_LONG);
const EVIOCGBIT_KEY: libc::Ioctl = ioc(
    IOC_READ,
    b'E',
    0x20 + EV_KEY,
    size_of::<[libc::c_ulong; KEY_WORDS]>(),
);

pub(crate) struct Control {
    pub(crate) running: AtomicBool,
    pub(crate) frames: AtomicU64,
    pub(crate) error: Mutex<Option<String>>,
}

struct Mapping {
    address: *mut u8,
    length: usize,
}

// The mapping is read by exactly one spawned thread and remains valid until it
// is dropped by that thread.
unsafe impl Send for Mapping {}

impl Mapping {
    fn as_slice(&self) -> &[u8] {
        // SAFETY: mmap returned this readable region and Mapping owns its lifetime.
        unsafe { slice::from_raw_parts(self.address, self.length) }
    }
}

impl Drop for Mapping {
    fn drop(&mut self) {
        // SAFETY: address and length came from one successful mmap call.
        unsafe { libc::munmap(self.address.cast(), self.length) };
    }
}

struct Stream {
    _framebuffer: File,
    mapping: Mapping,
    output: File,
    layout: Layout,
    width: usize,
    height: usize,
    source_offset: usize,
    source_stride: usize,
    destination_stride: usize,
    frame: Vec<u8>,
}

fn ioctl<T>(fd: RawFd, request: libc::Ioctl, value: &mut T) -> io::Result<()> {
    loop {
        // SAFETY: request identifies a kernel structure matching T and value is writable.
        let result = unsafe { libc::ioctl(fd, request, ptr::from_mut(value)) };
        if result >= 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn open(path: &str, flags: libc::c_int) -> Result<File, String> {
    let path_c =
        CString::new(path).map_err(|_| format!("device path contains a NUL byte: {path:?}"))?;
    // SAFETY: path_c is NUL terminated and flags require no mode argument.
    let descriptor = unsafe { libc::open(path_c.as_ptr(), flags | libc::O_CLOEXEC) };
    if descriptor < 0 {
        return Err(format!(
            "cannot open {path}: {}",
            io::Error::last_os_error()
        ));
    }
    // SAFETY: descriptor is newly opened and ownership transfers to File.
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

pub(crate) fn open_keyboard(paths: &[String]) -> Result<(File, String), String> {
    let mut last_error = "no keyboard event device found".to_owned();

    for path in paths {
        match open(path, libc::O_RDONLY) {
            Ok(device) if keyboard_capable(&device) => return Ok((device, path.clone())),
            Ok(_device) => last_error = format!("{path} is not a keyboard event device"),
            Err(error) => last_error = error,
        }
    }

    Err(last_error)
}

fn keyboard_capable(device: &File) -> bool {
    let mut keys = [0 as libc::c_ulong; KEY_WORDS];

    if ioctl(device.as_raw_fd(), EVIOCGBIT_KEY, &mut keys).is_err() {
        // Regular files are useful for ABI-level NIF tests but have no evdev ioctl.
        return device.metadata().is_ok_and(|metadata| metadata.is_file());
    }

    KEYBOARD_KEYS
        .iter()
        .all(|code| keys[code / BITS_PER_LONG] & (1 << (code % BITS_PER_LONG)) != 0)
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct InputEvent {
    seconds: libc::c_long,
    microseconds: libc::c_long,
    type_: u16,
    code: u16,
    value: i32,
}

pub(crate) fn read_input_event(device: &File) -> Result<Option<(u16, u16, i32)>, String> {
    let mut descriptor = libc::pollfd {
        fd: device.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };

    loop {
        // A finite wait lets a killed BEAM reader release its dirty scheduler promptly.
        // SAFETY: descriptor points to one valid pollfd for the duration of the call.
        let result = unsafe { libc::poll(ptr::from_mut(&mut descriptor), 1, 250) };
        if result == 0 {
            return Ok(None);
        }
        if result > 0 {
            break;
        }

        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(format!("cannot poll keyboard: {error}"));
        }
    }

    let mut event = InputEvent::default();
    // SAFETY: event is initialized and the byte slice covers exactly its storage.
    let bytes = unsafe {
        slice::from_raw_parts_mut(
            ptr::from_mut(&mut event).cast::<u8>(),
            size_of::<InputEvent>(),
        )
    };
    let mut reader = device;
    reader
        .read_exact(bytes)
        .map_err(|error| format!("cannot read keyboard: {error}"))?;
    Ok(Some((event.type_, event.code, event.value)))
}

impl Stream {
    fn open(
        framebuffer_path: &str,
        output_path: &str,
        fps: u32,
        x: u32,
        y: u32,
        requested_width: u32,
        requested_height: u32,
    ) -> Result<Self, String> {
        let framebuffer = open(framebuffer_path, libc::O_RDONLY)?;
        let mut fixed = FbFixScreeninfo::default();
        let mut variable = FbVarScreeninfo::default();
        ioctl(framebuffer.as_raw_fd(), FBIOGET_FSCREENINFO, &mut fixed)
            .map_err(|error| format!("cannot query {framebuffer_path}: {error}"))?;
        ioctl(framebuffer.as_raw_fd(), FBIOGET_VSCREENINFO, &mut variable)
            .map_err(|error| format!("cannot query {framebuffer_path}: {error}"))?;

        let capture_x = x as usize;
        let capture_y = y as usize;
        let screen_width = variable.xres as usize;
        let screen_height = variable.yres as usize;
        let width = if requested_width == 0 {
            screen_width.saturating_sub(capture_x)
        } else {
            requested_width as usize
        };
        let height = if requested_height == 0 {
            screen_height.saturating_sub(capture_y)
        } else {
            requested_height as usize
        };
        if width == 0 || height == 0 || !width.is_multiple_of(2) {
            return Err("capture dimensions must be non-zero with an even width".to_owned());
        }
        if capture_x
            .checked_add(width)
            .is_none_or(|end| end > screen_width)
            || capture_y
                .checked_add(height)
                .is_none_or(|end| end > screen_height)
        {
            return Err(format!(
                "capture region {width}x{height}+{capture_x}+{capture_y} exceeds framebuffer {}x{}",
                screen_width, screen_height
            ));
        }
        if fixed.visual != FB_VISUAL_TRUECOLOR
            || variable.grayscale != 0
            || variable.red.msb_right != 0
            || variable.green.msb_right != 0
            || variable.blue.msb_right != 0
        {
            return Err("framebuffer must use a true-color, LSB-first RGB layout".to_owned());
        }

        let layout = Layout {
            bytes_per_pixel: variable.bits_per_pixel.div_ceil(8) as usize,
            red: Channel {
                offset: variable.red.offset,
                length: variable.red.length,
            },
            green: Channel {
                offset: variable.green.offset,
                length: variable.green.length,
            },
            blue: Channel {
                offset: variable.blue.offset,
                length: variable.blue.length,
            },
        }
        .validate()?;
        let source_stride = fixed.line_length as usize;
        let absolute_x = (variable.xoffset as usize)
            .checked_add(capture_x)
            .ok_or_else(|| "framebuffer geometry overflow".to_owned())?;
        let absolute_y = (variable.yoffset as usize)
            .checked_add(capture_y)
            .ok_or_else(|| "framebuffer geometry overflow".to_owned())?;
        let row_end = absolute_x
            .checked_add(width)
            .ok_or_else(|| "framebuffer geometry overflow".to_owned())?
            .checked_mul(layout.bytes_per_pixel)
            .ok_or_else(|| "framebuffer geometry overflow".to_owned())?;
        if source_stride < row_end {
            return Err("framebuffer scanline is shorter than its visible geometry".to_owned());
        }
        let xoffset_bytes = absolute_x
            .checked_mul(layout.bytes_per_pixel)
            .ok_or_else(|| "framebuffer geometry overflow".to_owned())?;
        let source_offset = absolute_y
            .checked_mul(source_stride)
            .and_then(|offset| offset.checked_add(xoffset_bytes))
            .ok_or_else(|| "framebuffer geometry overflow".to_owned())?;
        let last_row_offset = (height - 1)
            .checked_mul(source_stride)
            .ok_or_else(|| "framebuffer geometry overflow".to_owned())?;
        let visible_row_bytes = width
            .checked_mul(layout.bytes_per_pixel)
            .ok_or_else(|| "framebuffer geometry overflow".to_owned())?;
        let visible_end = source_offset
            .checked_add(last_row_offset)
            .and_then(|offset| offset.checked_add(visible_row_bytes))
            .ok_or_else(|| "framebuffer geometry overflow".to_owned())?;
        if visible_end > fixed.smem_len as usize {
            return Err("framebuffer geometry exceeds mapped memory".to_owned());
        }

        // SAFETY: the framebuffer descriptor is valid and smem_len was supplied by its driver.
        let address = unsafe {
            libc::mmap(
                ptr::null_mut(),
                fixed.smem_len as usize,
                libc::PROT_READ,
                libc::MAP_SHARED,
                framebuffer.as_raw_fd(),
                0,
            )
        };
        if address == libc::MAP_FAILED {
            return Err(format!(
                "cannot map {framebuffer_path}: {}",
                io::Error::last_os_error()
            ));
        }
        let mapping = Mapping {
            address: address.cast(),
            length: fixed.smem_len as usize,
        };

        let output = open(output_path, libc::O_WRONLY | libc::O_NONBLOCK)?;
        let mut capability = V4l2Capability::default();
        ioctl(output.as_raw_fd(), VIDIOC_QUERYCAP, &mut capability)
            .map_err(|error| format!("cannot query {output_path}: {error}"))?;
        let caps = if capability.capabilities & V4L2_CAP_DEVICE_CAPS != 0 {
            capability.device_caps
        } else {
            capability.capabilities
        };
        if caps & V4L2_CAP_VIDEO_OUTPUT == 0 || caps & V4L2_CAP_READWRITE == 0 {
            return Err(format!(
                "{output_path} does not support single-plane write() video output"
            ));
        }

        let requested = V4l2PixFormat {
            width: width as u32,
            height: height as u32,
            pixelformat: V4L2_PIX_FMT_YUYV,
            field: V4L2_FIELD_NONE,
            colorspace: V4L2_COLORSPACE_SMPTE170M,
            ..V4l2PixFormat::default()
        };
        let mut format = V4l2Format {
            type_: V4L2_BUF_TYPE_VIDEO_OUTPUT,
            fmt: V4l2FormatData { pix: requested },
        };
        ioctl(output.as_raw_fd(), VIDIOC_S_FMT, &mut format)
            .map_err(|error| format!("cannot set YUYV output format on {output_path}: {error}"))?;
        // SAFETY: the active union member is pix for VIDEO_OUTPUT.
        let negotiated = unsafe { format.fmt.pix };
        if negotiated.width != width as u32
            || negotiated.height != height as u32
            || negotiated.pixelformat != V4L2_PIX_FMT_YUYV
        {
            return Err(format!(
                "{output_path} changed the requested {}x{} YUYV format",
                width, height
            ));
        }
        let mut parameters = V4l2StreamParm {
            type_: V4L2_BUF_TYPE_VIDEO_OUTPUT,
            parm: V4l2StreamParmData {
                output: V4l2OutputParm {
                    timeperframe: V4l2Fract {
                        numerator: 1,
                        denominator: fps,
                    },
                    ..V4l2OutputParm::default()
                },
            },
        };
        ioctl(output.as_raw_fd(), VIDIOC_S_PARM, &mut parameters)
            .map_err(|error| format!("cannot set {fps} fps on {output_path}: {error}"))?;
        let packed_stride = width
            .checked_mul(2)
            .ok_or_else(|| "V4L2 frame geometry overflow".to_owned())?;
        let destination_stride = (negotiated.bytesperline as usize).max(packed_stride);
        let frame_size = destination_stride
            .checked_mul(height)
            .ok_or_else(|| "V4L2 frame geometry overflow".to_owned())?
            .max(negotiated.sizeimage as usize);

        Ok(Self {
            _framebuffer: framebuffer,
            mapping,
            output,
            layout,
            width,
            height,
            source_offset,
            source_stride,
            destination_stride,
            frame: vec![0; frame_size],
        })
    }

    fn convert(&mut self) {
        let source = self.mapping.as_slice();
        for y in 0..self.height {
            let source_start = self.source_offset + y * self.source_stride;
            let destination_start = y * self.destination_stride;
            pixel::row_to_yuyv(
                &source[source_start..],
                &mut self.frame[destination_start..],
                self.width,
                self.layout,
            );
        }
    }

    fn write_frame(&mut self, running: &AtomicBool) -> io::Result<()> {
        while running.load(Ordering::Acquire) {
            match self.output.write(&self.frame) {
                Ok(length) if length == self.frame.len() => return Ok(()),
                Ok(length) => {
                    return Err(io::Error::other(format!(
                        "short V4L2 write: {length} bytes"
                    )));
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    let mut descriptor = libc::pollfd {
                        fd: self.output.as_raw_fd(),
                        events: libc::POLLOUT,
                        revents: 0,
                    };
                    // SAFETY: descriptor points to one initialized pollfd value.
                    let result = unsafe { libc::poll(&mut descriptor, 1, 100) };
                    if result < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted
                    {
                        return Err(io::Error::last_os_error());
                    }
                }
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
}

use std::os::fd::AsRawFd;

pub(crate) fn start(
    framebuffer: String,
    output: String,
    fps: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) -> Result<Arc<Control>, String> {
    if !(1..=1_000).contains(&fps) {
        return Err("fps must be between 1 and 1000".to_owned());
    }
    let mut stream = Stream::open(&framebuffer, &output, fps, x, y, width, height)?;
    let control = Arc::new(Control {
        running: AtomicBool::new(true),
        frames: AtomicU64::new(0),
        error: Mutex::new(None),
    });
    let worker_control = Arc::clone(&control);
    thread::Builder::new()
        .name("beamicom_v4l2".to_owned())
        .spawn(move || {
            let interval = Duration::from_nanos(1_000_000_000 / fps as u64);
            let mut deadline = Instant::now();
            while worker_control.running.load(Ordering::Acquire) {
                stream.convert();
                if let Err(error) = stream.write_frame(&worker_control.running) {
                    *worker_control
                        .error
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                        Some(format!("V4L2 write failed: {error}"));
                    break;
                }
                worker_control.frames.fetch_add(1, Ordering::Relaxed);
                deadline += interval;
                if let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
                    thread::sleep(remaining);
                }
            }
            worker_control.running.store(false, Ordering::Release);
        })
        .map_err(|error| format!("cannot start framebuffer thread: {error}"))?;
    Ok(control)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kernel_struct_sizes_match_linux_uapi() {
        #[cfg(target_pointer_width = "64")]
        assert_eq!(size_of::<FbFixScreeninfo>(), 80);
        #[cfg(target_pointer_width = "32")]
        assert_eq!(size_of::<FbFixScreeninfo>(), 68);
        assert_eq!(size_of::<FbVarScreeninfo>(), 160);
        assert_eq!(size_of::<V4l2Capability>(), 104);
        #[cfg(target_pointer_width = "64")]
        assert_eq!(size_of::<V4l2Format>(), 208);
        #[cfg(target_pointer_width = "32")]
        assert_eq!(size_of::<V4l2Format>(), 204);
        assert_eq!(size_of::<V4l2StreamParm>(), 204);
        #[cfg(target_pointer_width = "64")]
        assert_eq!(size_of::<InputEvent>(), 24);
        #[cfg(target_pointer_width = "32")]
        assert_eq!(size_of::<InputEvent>(), 16);
    }
}
