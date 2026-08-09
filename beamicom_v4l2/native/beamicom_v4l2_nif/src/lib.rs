mod linux;
mod pixel;

use rustler::Resource;
use std::fs::File;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::Ordering;

struct StreamResource {
    control: Arc<linux::Control>,
}

#[rustler::resource_impl]
impl Resource for StreamResource {}

impl Drop for StreamResource {
    fn drop(&mut self) {
        self.control.running.store(false, Ordering::Release);
    }
}

struct KeyboardResource {
    device: Mutex<File>,
}

#[rustler::resource_impl]
impl Resource for KeyboardResource {}

#[rustler::nif(schedule = "DirtyIo")]
fn start(
    framebuffer: String,
    output: String,
    fps: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) -> Result<rustler::ResourceArc<StreamResource>, String> {
    linux::start(framebuffer, output, fps, x, y, width, height)
        .map(|control| rustler::ResourceArc::new(StreamResource { control }))
}

#[rustler::nif]
fn stop(resource: rustler::ResourceArc<StreamResource>) -> bool {
    resource.control.running.swap(false, Ordering::AcqRel)
}

#[rustler::nif]
fn status(resource: rustler::ResourceArc<StreamResource>) -> (bool, u64, Option<String>) {
    let error = resource
        .control
        .error
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone();
    (
        resource.control.running.load(Ordering::Acquire),
        resource.control.frames.load(Ordering::Relaxed),
        error,
    )
}

#[rustler::nif(schedule = "DirtyIo")]
fn keyboard_open(
    paths: Vec<String>,
) -> Result<(rustler::ResourceArc<KeyboardResource>, String), String> {
    linux::open_keyboard(&paths).map(|(device, path)| {
        (
            rustler::ResourceArc::new(KeyboardResource {
                device: Mutex::new(device),
            }),
            path,
        )
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn keyboard_read(
    resource: rustler::ResourceArc<KeyboardResource>,
) -> Result<Option<(u16, u16, i32)>, String> {
    let device = resource
        .device
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    linux::read_input_event(&device)
}

rustler::init!("Elixir.BeamicomV4L2.Native");
