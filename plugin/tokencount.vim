if exists('g:loaded_tokencount') | finish | endif
let g:loaded_tokencount = 1

if !has('job') || !has('timers') | finish | endif
if v:version < 901 | finish | endif

let s:plugin_root = expand('<sfile>:p:h:h')
let g:tokencount_executable = get(g:, 'tokencount_executable',
    \ s:plugin_root . '/target/release/tokencount')

let g:tokencount_debounce_ms = get(g:, 'tokencount_debounce_ms', 40)
let g:tokencount_label       = get(g:, 'tokencount_label', 'Tok:')
let g:tokencount_fast        = get(g:, 'tokencount_fast', 0)

augroup tokencount
    autocmd!
    autocmd CursorMoved,ModeChanged * call tokencount#on_event()
augroup END

func! TokenCountStatus() abort
    return tokencount#status()
endfunc

command! TokenCountStatus echo tokencount#health()
command! -range=% TokenCount call tokencount#count_range(<line1>, <line2>)
