use base64::{engine::general_purpose::STANDARD, Engine};
use claude_tokenizer::count_tokens;
use std::io::{self, BufRead, Write};

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let mut lock = stdin.lock();
    let mut line = String::new();
    loop {
        line.clear();
        match lock.read_line(&mut line) {
            Ok(0) => break,
            Err(_) => break,
            Ok(_) => {}
        }
        let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
        let (seq, b64) = match trimmed.split_once(' ') {
            Some(p) => p,
            None => continue,
        };
        let bytes = match STANDARD.decode(b64) {
            Ok(b) => b,
            Err(_) => {
                let _ = writeln!(out, "{} 0", seq);
                let _ = out.flush();
                continue;
            }
        };
        let text = String::from_utf8_lossy(&bytes);
        let count = count_tokens(&text).unwrap_or(0);
        let _ = writeln!(out, "{} {}", seq, count);
        let _ = out.flush();
    }
}
