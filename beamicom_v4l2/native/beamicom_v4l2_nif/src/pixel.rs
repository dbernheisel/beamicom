#[derive(Clone, Copy, Debug)]
pub(crate) struct Channel {
    pub(crate) offset: u32,
    pub(crate) length: u32,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Layout {
    pub(crate) bytes_per_pixel: usize,
    pub(crate) red: Channel,
    pub(crate) green: Channel,
    pub(crate) blue: Channel,
}

impl Layout {
    pub(crate) fn validate(self) -> Result<Self, String> {
        if !(2..=4).contains(&self.bytes_per_pixel) {
            return Err(format!(
                "unsupported {}-byte framebuffer pixels",
                self.bytes_per_pixel
            ));
        }

        for channel in [self.red, self.green, self.blue] {
            if channel.length == 0
                || channel.length > 8
                || channel.offset + channel.length > (self.bytes_per_pixel * 8) as u32
            {
                return Err("unsupported framebuffer color channel layout".to_owned());
            }
        }

        Ok(self)
    }
}

fn channel(pixel: u32, channel: Channel) -> u8 {
    let mask = (1_u32 << channel.length) - 1;
    let value = (pixel >> channel.offset) & mask;
    ((value * 255 + mask / 2) / mask) as u8
}

fn rgb(bytes: &[u8], layout: Layout) -> (u8, u8, u8) {
    let mut packed = [0_u8; 4];
    packed[..layout.bytes_per_pixel].copy_from_slice(&bytes[..layout.bytes_per_pixel]);
    let pixel = u32::from_ne_bytes(packed);
    (
        channel(pixel, layout.red),
        channel(pixel, layout.green),
        channel(pixel, layout.blue),
    )
}

fn clamp(value: i32) -> u8 {
    value.clamp(0, 255) as u8
}

fn div_256_floor(value: i32) -> i32 {
    if value < 0 {
        -((-value + 255) / 256)
    } else {
        value / 256
    }
}

fn y(red: u8, green: u8, blue: u8) -> u8 {
    clamp(div_256_floor(66 * red as i32 + 129 * green as i32 + 25 * blue as i32 + 128) + 16)
}

fn u(red: u8, green: u8, blue: u8) -> u8 {
    clamp(div_256_floor(-38 * red as i32 - 74 * green as i32 + 112 * blue as i32 + 128) + 128)
}

fn v(red: u8, green: u8, blue: u8) -> u8 {
    clamp(div_256_floor(112 * red as i32 - 94 * green as i32 - 18 * blue as i32 + 128) + 128)
}

pub(crate) fn row_to_yuyv(source: &[u8], destination: &mut [u8], width: usize, layout: Layout) {
    for x in (0..width).step_by(2) {
        let first = rgb(&source[x * layout.bytes_per_pixel..], layout);
        let second = rgb(&source[(x + 1) * layout.bytes_per_pixel..], layout);
        let average = (
            (first.0 as u16 + second.0 as u16).div_ceil(2) as u8,
            (first.1 as u16 + second.1 as u16).div_ceil(2) as u8,
            (first.2 as u16 + second.2 as u16).div_ceil(2) as u8,
        );
        let output = &mut destination[x * 2..x * 2 + 4];
        output.copy_from_slice(&[
            y(first.0, first.1, first.2),
            u(average.0, average.1, average.2),
            y(second.0, second.1, second.2),
            v(average.0, average.1, average.2),
        ]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const XRGB8888: Layout = Layout {
        bytes_per_pixel: 4,
        red: Channel {
            offset: 16,
            length: 8,
        },
        green: Channel {
            offset: 8,
            length: 8,
        },
        blue: Channel {
            offset: 0,
            length: 8,
        },
    };

    #[test]
    fn converts_rgb565_channels() {
        let layout = Layout {
            bytes_per_pixel: 2,
            red: Channel {
                offset: 11,
                length: 5,
            },
            green: Channel {
                offset: 5,
                length: 6,
            },
            blue: Channel {
                offset: 0,
                length: 5,
            },
        };
        assert_eq!(rgb(&[0x00, 0xf8], layout), (255, 0, 0));
        assert_eq!(rgb(&[0xe0, 0x07], layout), (0, 255, 0));
    }

    #[test]
    fn converts_black_and_white_to_yuyv() {
        let source = [0, 0, 0, 0, 255, 255, 255, 0];
        let mut output = [0; 4];
        row_to_yuyv(&source, &mut output, 2, XRGB8888);
        assert_eq!(output, [16, 128, 235, 128]);
    }

    #[test]
    fn converts_red_to_yuyv() {
        let source = [0, 0, 255, 0, 0, 0, 255, 0];
        let mut output = [0; 4];
        row_to_yuyv(&source, &mut output, 2, XRGB8888);
        assert_eq!(output, [82, 90, 82, 240]);
    }
}
