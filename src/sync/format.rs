//! Files in the sync storage: gzip-compressed JSON lines for change batches and
//! snapshots, plain JSON for the library and device manifests.
use super::apply::{Base, Change};
use anyhow::{Context, Result, ensure};
use flate2::{Compression, read::GzDecoder, write::GzEncoder};
use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Write};

pub const FORMAT: i64 = 1;

pub fn batch_path(device: &str, seq: i64) -> String {
    format!("changes/{device}/{seq:010}.jsonl.gz")
}

pub fn device_path(device: &str) -> String {
    format!("devices/{device}.json")
}

fn gzip(lines: &[Value]) -> Result<Vec<u8>> {
    let mut out = GzEncoder::new(Vec::new(), Compression::default());
    for line in lines {
        serde_json::to_writer(&mut out, line)?;
        out.write_all(b"\n")?;
    }
    Ok(out.finish()?)
}

fn gunzip(bytes: &[u8]) -> Result<Vec<Value>> {
    let mut lines = Vec::new();
    for line in BufReader::new(GzDecoder::new(bytes)).lines() {
        let line = line?;
        if !line.trim().is_empty() {
            lines.push(serde_json::from_str(&line)?);
        }
    }
    Ok(lines)
}

fn clocks_of(v: &Value) -> std::collections::BTreeMap<String, String> {
    v.as_object()
        .into_iter()
        .flatten()
        .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
        .collect()
}

/// A batch of one device's changes. Every field of a change shares its clock.
pub fn write_batch(device: &str, seq: i64, created: &str, changes: &[Change]) -> Result<Vec<u8>> {
    let mut lines = vec![
        json!({"format":FORMAT,"device":device,"seq":seq,"created":created,"count":changes.len()}),
    ];
    for ch in changes {
        lines.push(match &ch.deleted {
            Some(hlc) => json!({"kind":ch.kind,"key":ch.key,"hlc":hlc,"deleted":true}),
            None => json!({"kind":ch.kind,"key":ch.key,"hlc":ch.clocks.values().max(),
                "fields":ch.fields,"prev":ch.prev}),
        });
    }
    gzip(&lines)
}

pub fn read_batch(bytes: &[u8]) -> Result<(Value, Vec<Change>)> {
    let lines = gunzip(bytes)?;
    let header = lines.first().cloned().context("Empty change batch")?;
    ensure!(
        header["format"].as_i64() == Some(FORMAT),
        "This change batch was written by a newer Omabib; update Omabib to keep syncing"
    );
    let device = header["device"].as_str().unwrap_or("").to_string();
    let mut changes = Vec::new();
    for line in &lines[1..] {
        let hlc = line["hlc"].as_str().unwrap_or("").to_string();
        let mut ch = Change {
            kind: line["kind"].as_str().unwrap_or("").into(),
            key: line["key"].as_str().unwrap_or("").into(),
            device: device.clone(),
            ..Default::default()
        };
        if line["deleted"] == true {
            ch.deleted = Some(hlc);
        } else {
            ch.fields = line["fields"].as_object().cloned().unwrap_or_default();
            ch.clocks = ch.fields.keys().map(|k| (k.clone(), hlc.clone())).collect();
            ch.prev = clocks_of(&line["prev"]);
        }
        changes.push(ch);
    }
    Ok((header, changes))
}

/// The full synced state, for computers joining the library.
pub fn write_snapshot(header: &Value, records: &[(String, String, Base)]) -> Result<Vec<u8>> {
    let mut lines = vec![header.clone()];
    for (kind, key, b) in records {
        lines.push(
            json!({"kind":kind,"key":key,"data":b.data,"clocks":b.clocks,"deleted":b.deleted}),
        );
    }
    gzip(&lines)
}

/// The snapshot's header and its records as changes, each field with its own clock.
pub fn read_snapshot(bytes: &[u8]) -> Result<(Value, Vec<Change>)> {
    let lines = gunzip(bytes)?;
    let header = lines.first().cloned().context("Empty snapshot")?;
    ensure!(
        header["format"].as_i64() == Some(FORMAT),
        "This library was written by a newer Omabib; update Omabib to use it"
    );
    let device = header["device"].as_str().unwrap_or("").to_string();
    let changes = lines[1..]
        .iter()
        .map(|line| Change {
            kind: line["kind"].as_str().unwrap_or("").into(),
            key: line["key"].as_str().unwrap_or("").into(),
            fields: line["data"].as_object().cloned().unwrap_or_else(Map::new),
            clocks: clocks_of(&line["clocks"]),
            prev: Default::default(),
            deleted: line["deleted"].as_str().map(str::to_owned),
            device: device.clone(),
        })
        .collect();
    Ok((header, changes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batches_and_snapshots_round_trip() {
        let mut ch = Change {
            kind: "note".into(),
            key: "n1".into(),
            device: "d1".into(),
            ..Default::default()
        };
        ch.fields.insert("body".into(), json!("Hello"));
        ch.clocks
            .insert("body".into(), "0000000001000.00000.d1".into());
        ch.prev
            .insert("body".into(), "0000000000500.00000.d2".into());
        let gone = Change {
            kind: "ref".into(),
            key: "r1".into(),
            deleted: Some("0000000002000.00000.d1".into()),
            device: "d1".into(),
            ..Default::default()
        };
        let bytes = write_batch("d1", 7, "now", &[ch.clone(), gone.clone()]).unwrap();
        let (header, back) = read_batch(&bytes).unwrap();
        assert_eq!(header["seq"], 7);
        assert_eq!(back, vec![ch, gone]);
        assert_eq!(batch_path("d1", 7), "changes/d1/0000000007.jsonl.gz");

        let mut b = Base::default();
        b.data.insert("title".into(), json!("T"));
        b.clocks
            .insert("title".into(), "0000000001000.00000.d1".into());
        let bytes = write_snapshot(
            &json!({"format":1,"device":"d1"}),
            &[("ref".into(), "r1".into(), b)],
        )
        .unwrap();
        let (_, records) = read_snapshot(&bytes).unwrap();
        assert_eq!(records[0].fields["title"], "T");
        assert_eq!(records[0].clocks["title"], "0000000001000.00000.d1");
        assert!(read_batch(&gzip(&[json!({"format":2})]).unwrap()).is_err());
    }
}
