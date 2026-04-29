use base64::{engine::general_purpose::STANDARD, Engine};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

struct Tokenizer {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Tokenizer {
    fn spawn() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_tokencount"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn tokencount");
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Self {
            child,
            stdin,
            stdout,
        }
    }

    fn send(&mut self, seq: &str, text: &str) {
        let line = format!("{} {}\n", seq, STANDARD.encode(text));
        self.stdin.write_all(line.as_bytes()).unwrap();
        self.stdin.flush().unwrap();
    }

    fn send_raw(&mut self, line: &str) {
        self.stdin.write_all(line.as_bytes()).unwrap();
        self.stdin.write_all(b"\n").unwrap();
        self.stdin.flush().unwrap();
    }

    fn recv(&mut self) -> (String, u32) {
        let mut line = String::new();
        self.stdout
            .read_line(&mut line)
            .expect("read reply line");
        let trimmed = line.trim_end();
        let (seq, count) = trimmed.split_once(' ').expect("reply lacks separator");
        (seq.to_string(), count.parse().expect("reply count is not a number"))
    }
}

impl Drop for Tokenizer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn ascii_hello_world() {
    let mut t = Tokenizer::spawn();
    t.send("1", "hello world");
    let (seq, count) = t.recv();
    assert_eq!(seq, "1");
    assert_eq!(count, 2);
}

#[test]
fn empty_payload_returns_zero_tokens() {
    let mut t = Tokenizer::spawn();
    t.send("1", "");
    let (seq, count) = t.recv();
    assert_eq!(seq, "1");
    assert_eq!(count, 0);
}

#[test]
fn multi_line_text_is_tokenized() {
    let mut t = Tokenizer::spawn();
    t.send("1", "line one\nline two\nline three");
    let (seq, count) = t.recv();
    assert_eq!(seq, "1");
    assert!(count >= 6, "expected several tokens, got {count}");
}

#[test]
fn cjk_and_emoji_round_trip() {
    let mut t = Tokenizer::spawn();
    let text = "こんにちは 🌍 hello";
    t.send("1", text);
    let (seq, count) = t.recv();
    assert_eq!(seq, "1");
    assert!(count > 0, "tokenizer returned 0 for {text:?}");
}

#[test]
fn pipelined_requests_preserve_order_and_seq() {
    let mut t = Tokenizer::spawn();
    let cases = [
        ("1", "alpha"),
        ("2", "beta gamma"),
        ("3", "the quick brown fox jumps over the lazy dog"),
        ("seq-r-1234", "sentinel-shaped sequence id"),
    ];
    for (seq, text) in &cases {
        t.send(seq, text);
    }
    for (seq, _text) in &cases {
        let (got_seq, count) = t.recv();
        assert_eq!(&got_seq, seq, "reply seq mismatch");
        assert!(count > 0, "expected nonzero count for seq {seq}");
    }
}

#[test]
fn invalid_base64_yields_zero_count() {
    let mut t = Tokenizer::spawn();
    t.send_raw("1 not_!!_valid_base64");
    let (seq, count) = t.recv();
    assert_eq!(seq, "1");
    assert_eq!(count, 0);
}

#[test]
fn malformed_line_without_separator_is_skipped() {
    let mut t = Tokenizer::spawn();
    t.send_raw("nospace_here");
    t.send("2", "after malformed");
    let (seq, count) = t.recv();
    assert_eq!(seq, "2");
    assert!(count > 0);
}

#[test]
fn long_payload_near_cap_succeeds() {
    let mut t = Tokenizer::spawn();
    let text = "abcdefghij ".repeat(15_000);
    t.send("1", &text);
    let (seq, count) = t.recv();
    assert_eq!(seq, "1");
    assert!(count > 1000, "expected many tokens, got {count}");
}

#[test]
fn large_one_megabyte_payload_succeeds() {
    let mut t = Tokenizer::spawn();
    let text = "the quick brown fox jumps over the lazy dog. ".repeat(25_000);
    assert!(text.len() >= 1_000_000, "test payload too small");
    t.send("1", &text);
    let (seq, count) = t.recv();
    assert_eq!(seq, "1");
    assert!(count > 100_000, "expected many tokens, got {count}");
}

#[test]
fn whitespace_only_payload() {
    let mut t = Tokenizer::spawn();
    t.send("1", "    \n\t\n   ");
    let (seq, count) = t.recv();
    assert_eq!(seq, "1");
    assert!(count > 0);
}

#[test]
fn ascii_count_matches_known_cl100k_values() {
    let mut t = Tokenizer::spawn();
    let cases = [
        ("hello", 1u32),
        ("hello world", 2u32),
        ("the quick brown fox", 4u32),
    ];
    for (text, expected) in &cases {
        t.send("1", text);
        let (_seq, count) = t.recv();
        assert_eq!(count, *expected, "cl100k count drift for {text:?}");
    }
}
