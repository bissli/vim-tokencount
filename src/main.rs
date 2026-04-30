use base64::{engine::general_purpose::STANDARD, Engine};
use std::collections::VecDeque;
use std::io::{self, BufRead, Write};
use tiktoken_rs::cl100k_base_singleton;

const SESSION_LRU_CAP: usize = 16;

struct Sessions {
    order: VecDeque<u64>,
    totals: std::collections::HashMap<u64, u32>,
}

impl Sessions {
    fn new() -> Self {
        Self {
            order: VecDeque::with_capacity(SESSION_LRU_CAP),
            totals: std::collections::HashMap::with_capacity(SESSION_LRU_CAP),
        }
    }

    fn touch(&mut self, sid: u64) {
        if let Some(pos) = self.order.iter().position(|x| *x == sid) {
            self.order.remove(pos);
        }
        self.order.push_back(sid);
        if self.order.len() > SESSION_LRU_CAP {
            if let Some(evict) = self.order.pop_front() {
                self.totals.remove(&evict);
            }
        }
    }

    fn add(&mut self, sid: u64, idx: u32, count: u32) -> u32 {
        if idx == 0 {
            self.totals.insert(sid, 0);
        }
        self.touch(sid);
        let entry = self.totals.entry(sid).or_insert(0);
        *entry = entry.saturating_add(count);
        *entry
    }
}

struct Request<'a> {
    seq: &'a str,
    sid: Option<u64>,
    idx: u32,
    payload: &'a str,
}

fn parse_request(line: &str) -> Option<Request<'_>> {
    let (seq, rest) = line.split_once(' ')?;
    if let Some(rest_after_session) = rest.strip_prefix("session=") {
        let (sid_str, rest) = rest_after_session.split_once(' ')?;
        let sid: u64 = sid_str.parse().ok()?;
        let rest = rest.strip_prefix("chunk=")?;
        let (chunk_field, payload) = rest.split_once(' ')?;
        let (idx_str, _total_str) = chunk_field.split_once('/')?;
        let idx: u32 = idx_str.parse().ok()?;
        Some(Request {
            seq,
            sid: Some(sid),
            idx,
            payload,
        })
    } else {
        Some(Request {
            seq,
            sid: None,
            idx: 0,
            payload: rest,
        })
    }
}

fn main() {
    let bpe_arc = cl100k_base_singleton();
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let mut lock = stdin.lock();
    let mut line = String::new();
    let mut sessions = Sessions::new();
    loop {
        line.clear();
        match lock.read_line(&mut line) {
            Ok(0) => break,
            Err(_) => break,
            Ok(_) => {}
        }
        let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
        let req = match parse_request(trimmed) {
            Some(r) => r,
            None => continue,
        };
        let bytes = match STANDARD.decode(req.payload) {
            Ok(b) => b,
            Err(_) => {
                let _ = writeln!(out, "{} 0", req.seq);
                let _ = out.flush();
                continue;
            }
        };
        let text = String::from_utf8_lossy(&bytes);
        let chunk_count = bpe_arc.lock().encode_with_special_tokens(&text).len() as u32;
        let reply = match req.sid {
            Some(sid) => sessions.add(sid, req.idx, chunk_count),
            None => chunk_count,
        };
        let _ = writeln!(out, "{} {}", req.seq, reply);
        let _ = out.flush();
    }
}
