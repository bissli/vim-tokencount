let s:job = v:null
let s:timer = -1
let s:next_seq = 0
let s:next_session = 0
let s:pending = {}

func! s:on_err(ch, msg) abort
    echohl WarningMsg
    echom 'tokencount: ' . a:msg
    echohl None
endfunc

func! s:start_job() abort
    if type(s:job) == v:t_job && job_status(s:job) ==# 'run'
        return v:true
    endif
    if !executable(g:tokencount_executable)
        return v:false
    endif
    let s:pending = {}
    let s:job = job_start([g:tokencount_executable], {
        \ 'in_mode': 'nl',
        \ 'out_mode': 'nl',
        \ 'noblock': 1,
        \ 'out_cb': function('s:on_reply'),
        \ 'err_cb': function('s:on_err'),
        \ 'stoponexit': 'term',
        \ })
    return type(s:job) == v:t_job
endfunc

func! s:redraw_soon() abort
    call timer_start(0, {-> execute('redrawstatus')})
endfunc

func! s:visual_lines() abort
    let m = mode()
    if m !~# "[vV\<C-v>]"
        return []
    endif
    return getregion(getpos('v'), getpos('.'), {'type': m})
endfunc

func! s:send_lines(lines, target) abort
    if !s:start_job()
        return 0
    endif
    let s:next_seq += 1
    let l:seq = s:next_seq
    let s:pending[l:seq] = a:target
    let l:payload = base64_encode(str2blob(a:lines))
    call ch_sendraw(s:job, l:seq . ' ' . l:payload . "\n")
    return l:seq
endfunc

func! s:send_chunk_payload(lines, sid, idx, total, target) abort
    if !s:start_job()
        return 0
    endif
    let s:next_seq += 1
    let l:seq = s:next_seq
    let s:pending[l:seq] = a:target
    let l:payload = base64_encode(str2blob(a:lines))
    call ch_sendraw(s:job, printf('%d session=%d chunk=%d/%d %s%s',
        \ l:seq, a:sid, a:idx, a:total, l:payload, "\n"))
    return l:seq
endfunc

func! s:on_reply(ch, msg) abort
    let l:parts = split(a:msg, ' ')
    if len(l:parts) != 2
        return
    endif
    let l:seq = str2nr(l:parts[0])
    let l:cnt = str2nr(l:parts[1])
    if !has_key(s:pending, l:seq)
        return
    endif
    let l:target = s:pending[l:seq]
    unlet s:pending[l:seq]
    if l:target.kind ==# 'buf'
        if has_key(l:target, 'session')
            if l:target.session != getbufvar(l:target.bufnr,
                \ 'tokencount_active_session', 0)
                return
            endif
        elseif l:seq < getbufvar(l:target.bufnr,
            \ 'tokencount_latest_seq', 0)
            return
        endif
        call setbufvar(l:target.bufnr, 'tokencount_value', l:cnt)
        call s:redraw_soon()
    elseif l:target.kind ==# 'echo'
        echom printf('%s %d', g:tokencount_label, l:cnt)
    endif
endfunc

func! s:fast_count(lines) abort
    let l:total = 0
    for l:line in a:lines
        let l:total += strcharlen(l:line)
    endfor
    return float2nr(l:total / 3.5)
endfunc

func! s:dispatch_chunk(state) abort
    let l:bufnr = a:state.bufnr
    if a:state.session != getbufvar(l:bufnr,
        \ 'tokencount_active_session', 0)
        return
    endif
    let l:idx = a:state.idx
    let l:total = a:state.total
    let l:l1 = a:state.l1 + l:idx * g:tokencount_chunk_lines
    let l:l2 = min([a:state.l2,
        \ l:l1 + g:tokencount_chunk_lines - 1])
    let l:lines = getbufline(l:bufnr, l:l1, l:l2)
    if !empty(l:lines)
        call s:send_chunk_payload(l:lines,
            \ a:state.session, l:idx, l:total,
            \ {'kind': 'buf', 'bufnr': l:bufnr,
            \  'session': a:state.session})
    endif
    if l:idx + 1 < l:total
        let l:next = copy(a:state)
        let l:next.idx = l:idx + 1
        call timer_start(0, {-> s:dispatch_chunk(l:next)})
    endif
endfunc

func! s:send() abort
    if mode() !~# "[vV\<C-v>]"
        let b:tokencount_value = 0
        call s:redraw_soon()
        return
    endif
    let l:m = mode()
    if l:m ==# 'V' && g:tokencount_chunk_lines > 0
        let l:l1 = min([line('v'), line('.')])
        let l:l2 = max([line('v'), line('.')])
        let l:nlines = l:l2 - l:l1 + 1
        if l:nlines <= 0
            let b:tokencount_value = 0
            call s:redraw_soon()
            return
        endif
        if g:tokencount_fast
            let l:lines = getbufline(bufnr('%'), l:l1, l:l2)
            let b:tokencount_value = s:fast_count(l:lines)
            call s:redraw_soon()
            return
        endif
        let s:next_session += 1
        let b:tokencount_active_session = s:next_session
        let l:total = (l:nlines + g:tokencount_chunk_lines - 1)
            \ / g:tokencount_chunk_lines
        let l:state = {
            \ 'bufnr': bufnr('%'),
            \ 'session': s:next_session,
            \ 'l1': l:l1,
            \ 'l2': l:l2,
            \ 'idx': 0,
            \ 'total': l:total,
            \ }
        call timer_start(0, {-> s:dispatch_chunk(l:state)})
        return
    endif
    let l:lines = s:visual_lines()
    if empty(l:lines) || (len(l:lines) == 1 && empty(l:lines[0]))
        let b:tokencount_value = 0
        call s:redraw_soon()
        return
    endif
    if g:tokencount_fast
        let b:tokencount_value = s:fast_count(l:lines)
        call s:redraw_soon()
        return
    endif
    let l:seq = s:send_lines(l:lines,
        \ {'kind': 'buf', 'bufnr': bufnr('%')})
    if l:seq > 0
        let b:tokencount_latest_seq = l:seq
    endif
endfunc

func! tokencount#on_event() abort
    if mode() !~# "[vV\<C-v>]"
        if exists('b:tokencount_value') && b:tokencount_value != 0
            let b:tokencount_value = 0
            call s:redraw_soon()
        endif
        return
    endif
    if s:timer != -1
        call timer_stop(s:timer)
    endif
    let s:timer = timer_start(g:tokencount_debounce_ms, {-> s:send()})
endfunc

func! tokencount#status() abort
    if !exists('b:tokencount_value') || b:tokencount_value == 0
        return ''
    endif
    return g:tokencount_label . ' ' . b:tokencount_value
endfunc

func! tokencount#health() abort
    let l:bin = g:tokencount_executable
    let l:exe = executable(l:bin) ? 'OK' : 'MISSING'
    let l:job = (type(s:job) == v:t_job && job_status(s:job) ==# 'run')
        \ ? 'running' : 'stopped'
    let l:mode = g:tokencount_fast ? 'fast (chars/3.5)' : 'rust binary'
    return printf('tokencount: mode=%s, binary=%s (%s), job=%s',
        \ l:mode, l:bin, l:exe, l:job)
endfunc

func! tokencount#count_range(l1, l2) abort
    let l:lines = getline(a:l1, a:l2)
    if empty(l:lines) || (len(l:lines) == 1 && empty(l:lines[0]))
        echo g:tokencount_label . ' 0'
        return
    endif
    if g:tokencount_fast
        echo printf('%s %d', g:tokencount_label, s:fast_count(l:lines))
        return
    endif
    if !s:send_lines(l:lines, {'kind': 'echo'})
        echo 'tokencount: binary missing; run `make build` in plugin root'
        return
    endif
    echo g:tokencount_label . ' ...'
endfunc

func! tokencount#_test_pend(seq, target) abort
    let s:pending[a:seq] = a:target
endfunc

func! tokencount#_test_dispatch(state) abort
    call s:dispatch_chunk(a:state)
endfunc
