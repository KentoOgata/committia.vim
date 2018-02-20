let s:PATH_SEP = has('win32') || has('win64') ? '\' : '/'

let g:committia#git#cmd = get(g:, 'committia#git#cmd', 'git')
let g:committia#git#diff_cmd = get(g:, 'committia#git#diff_cmd', 'diff -u --cached --no-color --no-ext-diff')
let g:committia#git#status_cmd = get(g:, 'committia#git#status_cmd', '-c color.status=false status -b')

try
    silent call vimproc#version()

    " Note: vimproc exists
    function! s:system(cmd) abort
        return vimproc#system(a:cmd)
    endfunction
    function! s:error_occurred() abort
        return vimproc#get_last_status()
    endfunction
catch /^Vim\%((\a\+)\)\=:E117/
    function! s:system(cmd) abort
        return system(a:cmd)
    endfunction
    function! s:error_occurred() abort
        return v:shell_error
    endfunction
endtry

if !executable(g:committia#git#cmd)
    echoerr g:committia#git#cmd . ' command is not found. Please check g:committia#git#cmd'
endif

function! s:extract_first_line(str) abort
    let i = stridx(a:str, "\r")
    if i > 0
        return a:str[: i - 1]
    endif
    let i = stridx(a:str, "\n")
    if i > 0
        return a:str[: i - 1]
    endif
    return a:str
endfunction

function! s:search_git_dir_and_work_tree() abort
    " '/.git' is unnecessary under submodule directory.
    let matched = matchlist(expand('%:p'), '[\\/]\.git[\\/]\%(\(modules\|worktrees\)[\\/].\+[\\/]\)\?\%(COMMIT_EDITMSG\|MERGE_MSG\)$')
    if len(matched) > 1
        let git_dir = expand('%:p:h')
        if matched[1] ==# 'worktrees'
            " Note:
            " This was added in #31. I'm not sure that the format of gitdir file
            " is fixed. Anyway, it works for now.
            let work_tree = fnamemodify(readfile(git_dir . '/gitdir')[0], ':h')
        else
            let work_tree = s:extract_first_line(s:system(printf('%s --git-dir="%s" rev-parse --show-toplevel', g:committia#git#cmd, escape(git_dir, '\'))))
            " TODO: Handle command error
        endif
        return [git_dir, work_tree]
    endif

    let output = s:system(g:committia#git#cmd . ' rev-parse --show-cdup')
    if s:error_occurred()
        throw "Failed to execute 'git rev-parse': " . output
    endif
    let root = s:extract_first_line(output)

    let git_dir = root . $GIT_DIR
    if !isdirectory(git_dir)
        throw 'Failed to get git-dir from $GIT_DIR'
    endif

    return [git_dir, fnamemodify(git_dir, ':h')]
endfunction

function! s:execute_git(cmd) abort
    try
        let [git_dir, work_tree] = s:search_git_dir_and_work_tree()
    catch
        throw 'committia: git: Failed to retrieve git-dir or work-tree: ' . v:exception
    endtry

    if git_dir ==# '' || work_tree ==# ''
        throw 'committia: git: Failed to retrieve git-dir or work-tree'
    endif

    let index_file_was_not_found = s:ensure_index_file(git_dir)
    try
        let cmd = printf('%s --git-dir="%s" --work-tree="%s" %s', g:committia#git#cmd, escape(git_dir, '\'), escape(work_tree, '\'), a:cmd)
        let out = s:system(cmd)
        if s:error_occurred()
            throw printf("committia: git: Failed to execute Git command '%s': %s", a:cmd, out)
        endif
        return out
    finally
        if index_file_was_not_found
            call s:unset_index_file()
        endif
    endtry
endfunction

function! s:ensure_index_file(git_dir) abort
    if $GIT_INDEX_FILE != ''
        return 0
    endif

    let s:lock_file = s:PATH_SEP . 'index.lock'
    if filereadable(s:lock_file)
        let $GIT_INDEX_FILE = s:lock_file
    else
        let $GIT_INDEX_FILE = a:git_dir . s:PATH_SEP . 'index'
    endif

    return 1
endfunction

function! s:unset_index_file() abort
    let $GIT_INDEX_FILE = ''
endfunction

function! committia#git#diff() abort
    let diff = s:execute_git(g:committia#git#diff_cmd)

    if diff !=# ''
        return split(diff, '\n')
    endif

    let line = s:diff_start_line()
    if line == -1
        return ['']
    endif

    return getline(line, '$')
endfunction

function! s:diff_start_line() abort
    let re_start_diff_line = '# -\+ >8 -\+\n\%(#.*\n\)\+diff --git'
    return search(re_start_diff_line, 'cenW')
endfunction

function! committia#git#status() abort
    try
        let status = s:execute_git(g:committia#git#status_cmd)
    catch /^committia: git: Failed to retrieve git-dir or work-tree/
        " Leave status window empty when git-dir or work-tree not found
        return ''
    endtry
    return map(split(status, '\n'), 'substitute(v:val, "^", "# ", "g")')
endfunction

function! committia#git#end_of_edit_region_line() abort
    let line = s:diff_start_line()
    if line == -1
        return 1
    endif
    while line > 1
        if stridx(getline(line - 1), '#') != 0
            break
        endif
        let line -= 1
    endwhile
    return line
endfunction
