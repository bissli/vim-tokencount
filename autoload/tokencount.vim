let s:job = v:null
let s:timer = -1

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
    return base64_encode(list2blob(str2list(a:txt, 1)))
endfunc

func! s:on_reply(ch, msg) abort
    let parts = split(a:msg, ' ')
    if len(parts) != 2
        return
    endif
    let seq = str2nr(parts[0])
    let cnt = str2nr(parts[1])
    if !exists('b:tokencount_pending') || seq != b:tokencount_pending
        return
    endif
    let b:tokencount_value = cnt
    call s:redraw_soon()
endfunc

func! s:send() abort
    if mode() !~# "[vV\<C-v>]"
        let b:tokencount_value = 0
        call s:redraw_soon()
        return
    endif
    let txt = s:visual_text()
    if empty(txt)
        let b:tokencount_value = 0
        call s:redraw_soon()
        return
    endif
    let bytes = strlen(txt)
    if bytes > g:tokencount_max_bytes
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
    let b:tokencount_pending = get(b:, 'tokencount_pending', 0) + 1
    call ch_sendraw(s:job, b:tokencount_pending . ' ' . s:b64(txt) . "\n")
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
