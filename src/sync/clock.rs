//! Hybrid logical clocks: wall-clock milliseconds, a counter for ties and the
//! device ID. Their text form sorts in clock order, so fields compare as strings.
use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Hlc {
    pub ms: u64,
    pub counter: u32,
    pub device: String,
}

impl Hlc {
    pub fn parse(s: &str) -> Option<Hlc> {
        let mut parts = s.splitn(3, '.');
        let ms = parts.next()?.parse().ok()?;
        let counter = parts.next()?.parse().ok()?;
        let device = parts.next()?.to_string();
        Some(Hlc {
            ms,
            counter,
            device,
        })
    }

    pub fn zero(device: &str) -> Hlc {
        Hlc {
            ms: 0,
            counter: 0,
            device: device.into(),
        }
    }

    /// The next clock for a local change made at `at_ms`: later than every
    /// clock this device has issued or seen.
    pub fn tick(&self, at_ms: u64, device: &str) -> Hlc {
        if at_ms > self.ms {
            Hlc {
                ms: at_ms,
                counter: 0,
                device: device.into(),
            }
        } else {
            Hlc {
                ms: self.ms,
                counter: self.counter + 1,
                device: device.into(),
            }
        }
    }

    /// This device's clock after seeing `other`.
    pub fn observe(&self, other: &Hlc) -> Hlc {
        if other.ms > self.ms || (other.ms == self.ms && other.counter > self.counter) {
            Hlc {
                ms: other.ms,
                counter: other.counter,
                device: self.device.clone(),
            }
        } else {
            self.clone()
        }
    }
}

impl fmt::Display for Hlc {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{:013}.{:05}.{}", self.ms, self.counter, self.device)
    }
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Milliseconds from an SQLite `strftime('%Y-%m-%dT%H:%M:%fZ')` timestamp.
pub fn iso_ms(s: &str) -> Option<u64> {
    let (date, time) = s.trim_end_matches('Z').split_once('T')?;
    let mut d = date.split('-').map(|x| x.parse::<i64>());
    let (y, m, day) = (d.next()?.ok()?, d.next()?.ok()?, d.next()?.ok()?);
    let mut t = time.split(':');
    let (h, min) = (
        t.next()?.parse::<i64>().ok()?,
        t.next()?.parse::<i64>().ok()?,
    );
    let sec: f64 = t.next()?.parse().ok()?;
    // Days from the civil date (Howard Hinnant's algorithm).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    let ms = ((days * 86400 + h * 3600 + min * 60) as f64 + sec) * 1000.0;
    (ms >= 0.0).then_some(ms.round() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clocks_sort_as_text_and_move_forward() {
        let a = Hlc::zero("a").tick(1000, "a");
        let b = a.tick(1000, "a");
        let c = b.tick(999, "a");
        assert!(a < b && b < c);
        assert!(a.to_string() < b.to_string() && b.to_string() < c.to_string());
        assert_eq!(Hlc::parse(&c.to_string()), Some(c.clone()));
        let seen = Hlc::zero("a").observe(&Hlc {
            ms: 5000,
            counter: 2,
            device: "b".into(),
        });
        assert_eq!(
            (seen.ms, seen.counter, seen.device.as_str()),
            (5000, 2, "a")
        );
        assert!(seen.tick(10, "a") > Hlc::parse("0000000005000.00002.b").unwrap());
        assert_eq!(iso_ms("1970-01-01T00:00:01.500Z"), Some(1500));
        assert_eq!(iso_ms("2026-09-18T10:00:00.000Z"), Some(1_789_725_600_000));
    }
}
