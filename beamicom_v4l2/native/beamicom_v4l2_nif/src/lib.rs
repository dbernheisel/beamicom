mod linux;
mod pixel;

use rustler::Resource;
use std::sync::Arc;
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

rustler::init!("Elixir.BeamicomV4L2.Native");
