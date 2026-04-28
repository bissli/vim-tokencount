# vim-tokencount

Live token counter for vim visual selections. Pipes the selection to a
long-lived Rust process that approximates Claude's tokenizer, with an
80ms debounce so the number updates as you extend the selection.

## Requirements

- Vim 9.1+ (uses `getregion()` and `base64_encode()`)
- `cargo` at install time, OR set `g:tokencount_fast = 1` to skip the
  binary and use a `chars / 3.5` heuristic

## Install (vim-plug)

```vim
Plug 'bissli/vim-tokencount', { 'do': 'make build' }
```

For a local checkout:

```vim
Plug 'file:///path/to/vim-tokencount', { 'do': 'make build' }
```

Then add a segment to your statusline:

```vim
set statusline+=\ %(\ %{TokenCountStatus()}%)
```

The `%(...%)` group collapses when the function returns an empty string,
so the segment only appears inside visual mode.

## Configuration

| variable                   | default                                   | meaning                                    |
| -------------------------- | ----------------------------------------- | ------------------------------------------ |
| `g:tokencount_executable`  | `<plugin_root>/target/release/tokencount` | binary path                                |
| `g:tokencount_debounce_ms` | `80`                                      | ms to wait after last cursor move          |
| `g:tokencount_max_bytes`   | `204800`                                  | selections above this show `>big`          |
| `g:tokencount_label`       | `Tok~`                                    | prefix shown before the count              |
| `g:tokencount_fast`        | `0`                                       | if `1`, skip the binary, use `bytes / 3.5` |

## Commands

- `:TokenCount` — count the whole buffer (or a range) one-shot
- `:TokenCountStatus` — health line: mode, binary path, job status

## Accuracy

The `claude-tokenizer` crate ships tokenizer data extracted from Anthropic's
Python SDK; it predates Claude 3 and was last updated in September 2024.
Expect roughly 9-16% mean absolute error vs. the official `count_tokens` API
on Claude 3.x and 4.x non-Opus-4.7 models, and 20-50% drift on Opus 4.7
(which ships a new tokenizer). The default `Tok~` label is a deliberate
honesty signal: this is an order-of-magnitude indicator, not a billing-grade
number.

If you need exact counts, drive Anthropic's `count_tokens` HTTP endpoint —
but a network roundtrip is too slow for a debounced statusline indicator.

## License

MIT.
