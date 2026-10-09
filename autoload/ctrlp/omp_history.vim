if exists('g:loaded_ctrlp_omp_history')
  finish
endif
let g:loaded_ctrlp_omp_history = 1

call add(g:ctrlp_ext_vars, {
  \ 'init': 'ctrlp#omp_history#init()',
  \ 'accept': 'ctrlp#omp_history#accept',
  \ 'lname': 'prompt history',
  \ 'sname': 'prompts',
  \ 'type': 'line',
  \ 'sort': 0,
  \ 'nolim': 1,
  \ })
let s:id = g:ctrlp_builtins + len(g:ctrlp_ext_vars)

function! ctrlp#omp_history#init()
  return v:lua.require('omp.history').items()
endfunction

function! ctrlp#omp_history#accept(mode, line)
  let index = str2nr(matchstr(a:line, '^\d\+'))
  if index == 0 | return | endif
  call ctrlp#exit()
  call v:lua.require('omp.history').select(index)
endfunction

function! ctrlp#omp_history#id()
  return s:id
endfunction
