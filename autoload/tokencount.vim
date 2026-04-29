let s:job = v:null
let s:timer = -1
let s:next_seq = 0
let s:pending_visual = {}

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
    let s:pending_visual = {}
    let s:job = job_start([g:tokencount_executable], {
        \ 'in_mode': 'nl',
        \ 'out_mode': 'nl',
        \ 'out_cb': function('s:on_reply'),
        \ 'err_cb': function('s:on_err'),
        \ 'stoponexit': 'term',
        \ })
    return type(s:job) == v:t_job
endfunc

func! s:visual_text() abort
    let m = mode()
    if m !~# "[vV\<C-v>]"
        return ''
    endif
    let lines = getregion(getpos('v'), getpos('.'), {'type': m})
    return join(lines, "\n")
endfunc

func! s:redraw_soon() abort
    call timer_start(0, {-> execute('redrawstatus')})
endfunc

func! s:b64(txt) abort
    " str2blob lands in vim 9.1.1016. Inside a single string \n means NUL,
    " so split on actual newlines and let str2blob rejoin with NL between
    " list elements. Falls back to a per-byte loop on older patches.
    if exists('*str2blob')
        return base64_encode(str2blob(split(a:txt, "\n", 1)))
    endif
    let blob = 0z
    let n = strlen(a:txt)
    let i = 0
    while i < n
        let blob += 0z00
        let blob[i] = char2nr(strpart(a:txt, i, 1))
        let i += 1
    endwhile
    return base64_encode(blob)
endfunc

func! s:selection_byte_upper_bound() abort
    let sp = getpos('v')
    let ep = getpos('.')
    let l1 = min([sp[1], ep[1]])
    let l2 = max([sp[1], ep[1]])
    if mode() ==# "\<C-v>"
        let cols = abs(ep[2] - sp[2]) + 1
        return cols * 4 * (l2 - l1 + 1) + (l2 - l1)
    endif
    let a = line2byte(l1)
    let b = line2byte(l2 + 1)
    if a < 0 || b < 0
        return g:tokencount_max_bytes + 1
    endif
    return b - a
endfunc

func! s:on_reply(ch, msg) abort
    let parts = split(a:msg, ' ')
    if len(parts) != 2
        return
    endif
    let seq = str2nr(parts[0])
    let cnt = str2nr(parts[1])
    if !has_key(s:pending_visual, seq)
        return
    endif
    let target = s:pending_visual[seq]
    unlet s:pending_visual[seq]
    call setbufvar(target, 'tokencount_value', cnt)
    call s:redraw_soon()
endfunc

func! s:send() abort
    if mode() !~# "[vV\<C-v>]"
        let b:tokencount_value = 0
        call s:redraw_soon()
        return
    endif
    if s:selection_byte_upper_bound() > g:tokencount_max_bytes
        let b:tokencount_value = -1
        call s:redraw_soon()
        return
    endif
    let txt = s:visual_text()
    if empty(txt)
        let b:tokencount_value = 0
        call s:redraw_soon()
        return
    endif
    if strlen(txt) > g:tokencount_max_bytes
        let b:tokencount_value = -1
        call s:redraw_soon()
        return
    endif
    if g:tokencount_fast
        let b:tokencount_value = float2nr(strcharlen(txt) / 3.5)
        call s:redraw_soon()
        return
    endif
    if !s:start_job()
        return
    endif
    let s:next_seq += 1
    let seq = s:next_seq
    let s:pending_visual[seq] = bufnr('%')
    call ch_sendraw(s:job, seq . ' ' . s:b64(txt) . "\n")
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
    if b:tokencount_value < 0
        return g:tokencount_label . ' >big'
    endif
    return g:tokencount_label . ' ' . b:tokencount_value
endfunc

func! tokencount#health() abort
    let bin = g:tokencount_executable
    let exe = executable(bin) ? 'OK' : 'MISSING'
    let job = (type(s:job) == v:t_job && job_status(s:job) ==# 'run') ? 'running' : 'stopped'
    let mode = g:tokencount_fast ? 'fast (chars/3.5)' : 'rust binary'
    return printf('tokencount: mode=%s, binary=%s (%s), job=%s', mode, bin, exe, job)
endfunc

func! tokencount#count_range(l1, l2) abort
    let a = line2byte(a:l1)
    let b = line2byte(a:l2 + 1)
    if a < 0 || b < 0 || (b - a) > g:tokencount_max_bytes
        echo g:tokencount_label . ' >big'
        return
    endif
    let txt = join(getline(a:l1, a:l2), "\n")
    if empty(txt)
        echo g:tokencount_label . ' 0'
        return
    endif
    if g:tokencount_fast
        echo printf('%s %d', g:tokencount_label, float2nr(strcharlen(txt) / 3.5))
        return
    endif
    if !s:start_job()
        echo 'tokencount: binary missing; run `make build` in plugin root'
        return
    endif
    let ch = job_getchannel(s:job)
    let sentinel = 'r' . reltimestr(reltime())
    let sentinel = substitute(sentinel, '\.', '', 'g')
    let reply = ch_evalraw(ch, sentinel . ' ' . s:b64(txt) . "\n",
        \ {'timeout': 5000})
    let parts = split(reply, ' ')
    if len(parts) == 2 && parts[0] ==# sentinel
        echo printf('%s %d', g:tokencount_label, str2nr(parts[1]))
    else
        echo g:tokencount_label . ' (no reply)'
    endif
endfunc
