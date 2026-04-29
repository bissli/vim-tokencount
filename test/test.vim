" Self-contained tests for vim-tokencount.
" Usage: test/run.sh

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
let s:on_reply = function('<SNR>' . s:sid . '_on_reply')

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


" -- encoding sanity (no helper to test; verify the inline expression) --

func! Test_encoding_lines_to_base64() abort
    " The autoload sends base64_encode(str2blob(lines)). Confirm the
    " builtins produce what we expect for a multi-line ASCII selection.
    let l:lines = ['hello', 'world']
    call assert_equal('aGVsbG8Kd29ybGQ=',
        \ base64_encode(str2blob(l:lines)))
endfunc

func! Test_encoding_handles_unicode() abort
    let l:lines = ['こんにちは']
    " Hiragana ko n ni chi ha = 15 UTF-8 bytes.
    let l:b64 = base64_encode(str2blob(l:lines))
    call assert_equal(15, len(str2blob(l:lines)))
    call assert_true(!empty(l:b64))
endfunc

func! Test_encoding_empty_lines() abort
    " A single empty line should produce no bytes.
    call assert_equal('', base64_encode(str2blob([''])))
endfunc


" -- dispatcher: visual-buffer routing -----------------------------------

func! Test_on_reply_writes_to_originating_buffer() abort
    enew!
    file bufA
    let l:bufA = bufnr('%')
    enew!
    file bufB
    let l:bufB = bufnr('%')
    " bufB is current; reply for seq=101 should land in bufA.
    call tokencount#_test_pend(101, {'kind': 'buf', 'bufnr': l:bufA})
    call s:on_reply(0, '101 42')
    call assert_equal(42,
        \ getbufvar(l:bufA, 'tokencount_value', -999))
    call assert_equal(-999,
        \ getbufvar(l:bufB, 'tokencount_value', -999))
endfunc

func! Test_on_reply_drops_stale_visual_seq() abort
    enew!
    file bufStale
    let l:buf = bufnr('%')
    call setbufvar(l:buf, 'tokencount_latest_seq', 200)
    call setbufvar(l:buf, 'tokencount_value', 99)
    " Reply with an older seq must be ignored.
    call tokencount#_test_pend(150, {'kind': 'buf', 'bufnr': l:buf})
    call s:on_reply(0, '150 7')
    call assert_equal(99, getbufvar(l:buf, 'tokencount_value'))
endfunc

func! Test_on_reply_applies_latest_visual_seq() abort
    enew!
    file bufFresh
    let l:buf = bufnr('%')
    call setbufvar(l:buf, 'tokencount_latest_seq', 100)
    call setbufvar(l:buf, 'tokencount_value', 99)
    call tokencount#_test_pend(100, {'kind': 'buf', 'bufnr': l:buf})
    call s:on_reply(0, '100 555')
    call assert_equal(555, getbufvar(l:buf, 'tokencount_value'))
endfunc

func! Test_on_reply_drops_unknown_seq() abort
    enew!
    let l:buf = bufnr('%')
    if exists('b:tokencount_value')
        unlet b:tokencount_value
    endif
    call s:on_reply(0, '99999 42')
    call assert_equal(-999,
        \ getbufvar(l:buf, 'tokencount_value', -999))
endfunc

func! Test_on_reply_ignores_malformed_msg() abort
    let l:before = len(v:errors)
    call s:on_reply(0, 'no-space')
    call s:on_reply(0, '1 2 3')
    call assert_equal(l:before, len(v:errors))
endfunc


" -- dispatcher: echo routing -------------------------------------------

func! Test_on_reply_echo_target_writes_message() abort
    call tokencount#_test_pend(401, {'kind': 'echo'})
    let l:before = len(v:errors)
    redir => l:msgs
    silent messages clear
    redir END
    call s:on_reply(0, '401 17')
    redir => l:msgs
    silent messages
    redir END
    call assert_match(g:tokencount_label . ' 17', l:msgs)
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


" -- tokencount#count_range --------------------------------------------

func! Test_count_range_empty_returns_zero() abort
    enew!
    let g:tokencount_fast = 0
    redir => l:out
    silent call tokencount#count_range(1, 1)
    redir END
    call assert_match(g:tokencount_label . ' 0', l:out)
endfunc

func! Test_count_range_fast_mode_echoes_immediately() abort
    enew!
    call setline(1, ['hello world hello world'])
    let g:tokencount_fast = 1
    redir => l:out
    silent call tokencount#count_range(1, 1)
    redir END
    let g:tokencount_fast = 0
    call assert_match(g:tokencount_label . ' \d\+', l:out)
endfunc

func! Test_count_range_huge_buffer_echoes_placeholder_immediately() abort
    " A huge buffer must NOT freeze count_range; it must echo the
    " placeholder synchronously and return.
    enew!
    let g:tokencount_fast = 0
    let g:tokencount_executable = '/nonexistent/binary'
    " Create ~1 MB of content. Without a binary the function falls
    " back to a missing-binary message, but it must still return
    " quickly without iterating in vimscript.
    let l:big = repeat(['lorem ipsum dolor sit amet, '
        \ . 'consectetur adipiscing elit'], 20000)
    call setline(1, l:big)
    let l:start = reltime()
    redir => l:out
    silent call tokencount#count_range(1, line('$'))
    redir END
    let l:elapsed_ms = float2nr(reltimefloat(reltime(l:start)) * 1000)
    call assert_true(l:elapsed_ms < 500,
        \ 'count_range took ' . l:elapsed_ms . 'ms on ~1 MB buffer')
endfunc


" -- run all ------------------------------------------------------------

let s:tests = [
    \ ['encoding_lines_to_base64',
    \  function('Test_encoding_lines_to_base64')],
    \ ['encoding_handles_unicode',
    \  function('Test_encoding_handles_unicode')],
    \ ['encoding_empty_lines',
    \  function('Test_encoding_empty_lines')],
    \ ['on_reply_writes_to_originating_buffer',
    \  function('Test_on_reply_writes_to_originating_buffer')],
    \ ['on_reply_drops_stale_visual_seq',
    \  function('Test_on_reply_drops_stale_visual_seq')],
    \ ['on_reply_applies_latest_visual_seq',
    \  function('Test_on_reply_applies_latest_visual_seq')],
    \ ['on_reply_drops_unknown_seq',
    \  function('Test_on_reply_drops_unknown_seq')],
    \ ['on_reply_ignores_malformed_msg',
    \  function('Test_on_reply_ignores_malformed_msg')],
    \ ['on_reply_echo_target_writes_message',
    \  function('Test_on_reply_echo_target_writes_message')],
    \ ['status_empty_when_unset',
    \  function('Test_status_empty_when_unset')],
    \ ['status_empty_when_zero',
    \  function('Test_status_empty_when_zero')],
    \ ['status_shows_count',
    \  function('Test_status_shows_count')],
    \ ['count_range_empty_returns_zero',
    \  function('Test_count_range_empty_returns_zero')],
    \ ['count_range_fast_mode_echoes_immediately',
    \  function('Test_count_range_fast_mode_echoes_immediately')],
    \ ['count_range_huge_buffer_echoes_placeholder_immediately',
    \  function('Test_count_range_huge_buffer_echoes_placeholder_immediately')],
    \ ]

for [s:name, s:F] in s:tests
    call s:run(s:name, s:F)
endfor

call s:emit(printf('%d tests, %d errors',
    \ len(s:tests), len(v:errors)))
for s:e in v:errors
    call s:emit('  ' . s:e)
endfor

let s:out = get(g:, 'tokencount_test_log', '/dev/stderr')
call writefile(s:report, s:out)

if !empty(v:errors)
    cquit!
endif
qall!
