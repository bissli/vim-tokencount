" Self-contained tests for vim-tokencount.
" Usage: vim -es -u NONE -i NONE -c 'set nocp' -S test/test.vim

set rtp+=.
let s:plugin_root = expand('<sfile>:p:h:h')
execute 'set rtp+=' . s:plugin_root
execute 'source ' . s:plugin_root . '/plugin/tokencount.vim'
execute 'source ' . s:plugin_root . '/autoload/tokencount.vim'

let v:errors = []

func! s:autoload_sid() abort
    redir => l:scripts
    silent scriptnames
    redir END
    for l:line in split(l:scripts, '\n')
        if l:line =~# 'autoload/tokencount\.vim'
            return matchstr(l:line, '^\s*\zs\d\+')
        endif
    endfor
    call assert_report('autoload/tokencount.vim not in :scriptnames')
    return ''
endfunc

let s:sid = s:autoload_sid()
let s:b64       = function('<SNR>' . s:sid . '_b64')
let s:on_reply  = function('<SNR>' . s:sid . '_on_reply')

let s:report = []

func! s:emit(line) abort
    call add(s:report, a:line)
endfunc

func! s:run(name, F) abort
    let l:before = len(v:errors)
    try
        call a:F()
    catch
        call assert_report('exception in ' . a:name . ': ' . v:exception
            \ . ' @ ' . v:throwpoint)
    endtry
    let l:after = len(v:errors)
    if l:after > l:before
        call s:emit(printf('FAIL %s', a:name))
    else
        call s:emit(printf('ok   %s', a:name))
    endif
endfunc


" -- s:b64 --------------------------------------------------------------

func! Test_b64_ascii() abort
    call assert_equal('aGVsbG8gd29ybGQ=', s:b64('hello world'))
endfunc

func! Test_b64_empty() abort
    call assert_equal('', s:b64(''))
endfunc

func! Test_b64_multiline_preserves_newlines() abort
    " Internal \n must round-trip as 0x0A bytes, not NUL.
    call assert_equal('YQpiCmM=', s:b64("a\nb\nc"))
endfunc

func! Test_b64_leading_and_trailing_newlines() abort
    call assert_equal('CmFiYwo=', s:b64("\nabc\n"))
endfunc

func! Test_b64_unicode() abort
    " Hiragana ko, n, ni, chi, ha
    call assert_equal('44GT44KT44Gr44Gh44Gv',
        \ s:b64("こんにちは"))
endfunc

func! Test_b64_str2blob_path_matches_loop_path() abort
    " Force the fallback loop and compare against the str2blob path.
    let l:saved = exists('*str2blob')
    if !l:saved
        return
    endif
    let l:samples = ['', 'hi', "a\nb", "中文", "tab\there"]
    let l:fast = map(copy(l:samples), 's:b64(v:val)')
    let l:slow = []
    for l:txt in l:samples
        let l:blob = 0z
        let l:n = strlen(l:txt)
        let l:i = 0
        while l:i < l:n
            let l:blob += 0z00
            let l:blob[l:i] = char2nr(strpart(l:txt, l:i, 1))
            let l:i += 1
        endwhile
        call add(l:slow, base64_encode(l:blob))
    endfor
    call assert_equal(l:slow, l:fast)
endfunc


" -- bound (via tokencount#_test_bound) ---------------------------------

func! s:populate(lines) abort
    enew!
    call setline(1, a:lines)
endfunc

func! Test_bound_linewise_full_buffer() abort
    call s:populate(['aaaa', 'bbbb', 'cccc', 'dddd', 'eeee'])
    " V mode, lines 1..5: 5 lines x (4 ASCII + 1 NL) = 25 bytes.
    let l:b = tokencount#_test_bound('V', [0, 1, 1, 0], [0, 5, 4, 0])
    call assert_equal(25, l:b)
endfunc

func! Test_bound_charwise_two_lines() abort
    call s:populate(['aaaa', 'bbbb', 'cccc'])
    " v mode, lines 1..2: line2byte upper bound counts full lines.
    " 2 lines x (4 + 1) = 10.
    let l:b = tokencount#_test_bound('v', [0, 1, 1, 0], [0, 2, 4, 0])
    call assert_equal(10, l:b)
endfunc

func! Test_bound_blockwise_uses_column_count() abort
    call s:populate(['aaaaa', 'bbbbb', 'ccccc'])
    " <C-v> 2 columns x 3 rows: 2 * 4 * 3 + (3 - 1) = 26.
    let l:b = tokencount#_test_bound("\<C-v>", [0, 1, 1, 0], [0, 3, 2, 0])
    call assert_equal(26, l:b)
endfunc

func! Test_bound_blockwise_does_not_explode_on_wide_lines() abort
    call s:populate(repeat([repeat('x', 5000)], 200))
    let g:tokencount_max_bytes = 200000
    " 1 column x 2 rows on 5000-wide lines: must be tiny, not 10000.
    let l:b = tokencount#_test_bound("\<C-v>", [0, 1, 1, 0], [0, 2, 1, 0])
    call assert_true(l:b < g:tokencount_max_bytes,
        \ 'narrow blockwise on wide lines must not be flagged big, got '
        \ . l:b)
endfunc

func! Test_bound_returns_zero_when_line2byte_negative() abort
    enew!
    " Fresh empty buffer: line2byte returns -1. Bound must return 0
    " (fall through) rather than a negative number that would mark the
    " selection as oversized incorrectly.
    let l:b = tokencount#_test_bound('v', [0, 1, 1, 0], [0, 1, 1, 0])
    call assert_equal(0, l:b)
endfunc


" -- s:on_reply / dispatcher --------------------------------------------

func! Test_on_reply_writes_to_originating_buffer() abort
    " Two buffers. Mark seq=101 as belonging to A. Switch to B, deliver
    " reply, confirm A got the value, B did not.
    enew!
    file bufA
    let l:bufA = bufnr('%')
    enew!
    file bufB
    let l:bufB = bufnr('%')
    call tokencount#_test_pend(101, l:bufA)
    call s:on_reply(0, '101 42')
    call assert_equal(42, getbufvar(l:bufA, 'tokencount_value', -999))
    call assert_equal(-999, getbufvar(l:bufB, 'tokencount_value', -999))
endfunc

func! Test_on_reply_drops_unknown_seq() abort
    enew!
    let l:buf = bufnr('%')
    if exists('b:tokencount_value')
        unlet b:tokencount_value
    endif
    call s:on_reply(0, '99999 42')
    call assert_equal(-999, getbufvar(l:buf, 'tokencount_value', -999))
endfunc

func! Test_on_reply_ignores_malformed_msg() abort
    let l:before = len(v:errors)
    call s:on_reply(0, 'no-space')
    call s:on_reply(0, '1 2 3')
    call assert_equal(l:before, len(v:errors))
endfunc


" -- tokencount#status --------------------------------------------------

func! Test_status_empty_when_unset() abort
    enew!
    if exists('b:tokencount_value')
        unlet b:tokencount_value
    endif
    call assert_equal('', tokencount#status())
endfunc

func! Test_status_empty_when_zero() abort
    enew!
    let b:tokencount_value = 0
    call assert_equal('', tokencount#status())
endfunc

func! Test_status_shows_count() abort
    enew!
    let b:tokencount_value = 17
    call assert_equal(g:tokencount_label . ' 17', tokencount#status())
endfunc

func! Test_status_shows_big_when_negative() abort
    enew!
    let b:tokencount_value = -1
    call assert_equal(g:tokencount_label . ' >big', tokencount#status())
endfunc


" -- tokencount#count_range guard ---------------------------------------

func! Test_count_range_big_buffer_short_circuits() abort
    enew!
    let g:tokencount_max_bytes = 1024
    " Build 4 KB of content: easily over 1 KB cap.
    let l:big = repeat(['lorem ipsum dolor sit amet, consectetur adipiscing'], 100)
    call setline(1, l:big)
    redir => l:out
    silent call tokencount#count_range(1, line('$'))
    redir END
    call assert_match('>big', l:out)
endfunc

func! Test_count_range_uses_fast_mode_when_set() abort
    enew!
    let g:tokencount_max_bytes = 200000
    let g:tokencount_fast = 1
    call setline(1, ['hello world hello world'])
    redir => l:out
    silent call tokencount#count_range(1, 1)
    redir END
    let g:tokencount_fast = 0
    " 23 chars / 3.5 ~= 6
    call assert_match(g:tokencount_label . ' \d\+', l:out)
endfunc

func! Test_count_range_empty_returns_zero() abort
    enew!
    let g:tokencount_max_bytes = 200000
    let g:tokencount_fast = 0
    redir => l:out
    silent call tokencount#count_range(1, 1)
    redir END
    call assert_match(g:tokencount_label . ' 0', l:out)
endfunc


" -- run all ------------------------------------------------------------

let s:tests = [
    \ ['b64_ascii', function('Test_b64_ascii')],
    \ ['b64_empty', function('Test_b64_empty')],
    \ ['b64_multiline_preserves_newlines',
    \  function('Test_b64_multiline_preserves_newlines')],
    \ ['b64_leading_and_trailing_newlines',
    \  function('Test_b64_leading_and_trailing_newlines')],
    \ ['b64_unicode', function('Test_b64_unicode')],
    \ ['b64_str2blob_path_matches_loop_path',
    \  function('Test_b64_str2blob_path_matches_loop_path')],
    \ ['bound_linewise_full_buffer',
    \  function('Test_bound_linewise_full_buffer')],
    \ ['bound_charwise_two_lines',
    \  function('Test_bound_charwise_two_lines')],
    \ ['bound_blockwise_uses_column_count',
    \  function('Test_bound_blockwise_uses_column_count')],
    \ ['bound_blockwise_does_not_explode_on_wide_lines',
    \  function('Test_bound_blockwise_does_not_explode_on_wide_lines')],
    \ ['bound_returns_zero_when_line2byte_negative',
    \  function('Test_bound_returns_zero_when_line2byte_negative')],
    \ ['on_reply_writes_to_originating_buffer',
    \  function('Test_on_reply_writes_to_originating_buffer')],
    \ ['on_reply_drops_unknown_seq',
    \  function('Test_on_reply_drops_unknown_seq')],
    \ ['on_reply_ignores_malformed_msg',
    \  function('Test_on_reply_ignores_malformed_msg')],
    \ ['status_empty_when_unset',
    \  function('Test_status_empty_when_unset')],
    \ ['status_empty_when_zero', function('Test_status_empty_when_zero')],
    \ ['status_shows_count', function('Test_status_shows_count')],
    \ ['status_shows_big_when_negative',
    \  function('Test_status_shows_big_when_negative')],
    \ ['count_range_big_buffer_short_circuits',
    \  function('Test_count_range_big_buffer_short_circuits')],
    \ ['count_range_uses_fast_mode_when_set',
    \  function('Test_count_range_uses_fast_mode_when_set')],
    \ ['count_range_empty_returns_zero',
    \  function('Test_count_range_empty_returns_zero')],
    \ ]

for [s:name, s:F] in s:tests
    call s:run(s:name, s:F)
endfor

call s:emit(printf('%d tests, %d errors', len(s:tests), len(v:errors)))
for s:e in v:errors
    call s:emit('  ' . s:e)
endfor

let s:out = get(g:, 'tokencount_test_log', '/dev/stderr')
call writefile(s:report, s:out)

if !empty(v:errors)
    cquit!
endif
qall!
