typeset -g HISTDB_ISEARCH_N
typeset -g HISTDB_ISEARCH_MATCH
typeset -g HISTDB_ISEARCH_DIR
typeset -g HISTDB_ISEARCH_DATE

# TODO Show more info about match (n, date, pwd, host)
# TODO Keys to limit match?

# make a keymap for histdb isearch
bindkey -N histdb-isearch main

_histdb_isearch_query () {
    if [[ -z $BUFFER ]]; then
       HISTDB_ISEARCH_MATCH=""
       return
    fi

    if (( $HISTDB_ISEARCH_N < 0 )); then
        local maxmin="min"
        local ascdesc="asc"
        local offset=$(( - $HISTDB_ISEARCH_N ))
    else
        local maxmin="max"
        local ascdesc="desc"
        local offset=$(( $HISTDB_ISEARCH_N ))
    fi

    local query="select
commands.argv,
places.dir,
datetime(max(history.start_time), 'unixepoch')
from history left join commands
on history.command_id = commands.rowid
left join places
on history.place_id = places.rowid
where commands.argv like '%$(sql_escape ${BUFFER})%'
group by commands.argv, places.dir
order by $maxmin(history.start_time) $ascdesc
limit 1
offset ${offset}"
    local result=$(_histdb_query -separator $'\n' "$query")
    local lines=("${(f)result}")
    HISTDB_ISEARCH_DATE=${lines[-1]}
    HISTDB_ISEARCH_DIR=${lines[-2]}
    lines[-1]=()
    lines[-1]=()
    HISTDB_ISEARCH_MATCH=${(F)lines}
}

_histdb_isearch_display () {
    if [[ -z ${HISTDB_ISEARCH_MATCH} ]]; then
        PREDISPLAY="(no match)
histdb($HISTDB_ISEARCH_N): "
    else
        local prefix="${HISTDB_ISEARCH_MATCH%%${BUFFER}*}"
        local prefix_len="${#prefix}"
        local match_len="${#BUFFER}"
        local match_end=$(( $match_len + $prefix_len ))
        region_highlight=("P${prefix_len} ${match_end} underline")
        PREDISPLAY="${HISTDB_ISEARCH_MATCH}
→ in ${HISTDB_ISEARCH_DIR}
→ on ${HISTDB_ISEARCH_DATE}
histdb($HISTDB_ISEARCH_N): "
    fi
}

_histdb-isearch-up () {
    HISTDB_ISEARCH_N=$(( $HISTDB_ISEARCH_N + 1 ))
    _histdb_isearch_query
    _histdb_isearch_display
}

_histdb-isearch-down () {
    HISTDB_ISEARCH_N=$(( $HISTDB_ISEARCH_N - 1 ))
    _histdb_isearch_query
    _histdb_isearch_display
}

# define a self-insert command for it (requires other code)
self-insert-histdb-isearch () {
    zle .self-insert
    _histdb_isearch_query
    _histdb_isearch_display
}

zle -N self-insert-histdb-isearch

_histdb-isearch () {
    HISTDB_ISEARCH_N=0
    echo -ne "\e[4 q" # switch to underline cursor

    zle -N self-insert self-insert-histdb-isearch
    zle -K histdb-isearch
    _histdb_isearch_query
    _histdb_isearch_display
    zle recursive-edit
    zle -A .self-insert self-insert

    local stat=$?

    zle -K main
    PREDISPLAY=""
    region_highlight=()

    echo -ne "\e[1 q" #box cursor

    if ! (( stat )); then
        BUFFER="${HISTDB_ISEARCH_MATCH}"
    fi

    return 0
}

zle -N _histdb-isearch-up
zle -N _histdb-isearch-down
zle -N _histdb-isearch

bindkey -M histdb-isearch '' _histdb-isearch-up
bindkey -M histdb-isearch '^[[A' _histdb-isearch-up

bindkey -M histdb-isearch '' _histdb-isearch-down
bindkey -M histdb-isearch '^[[B' _histdb-isearch-down

# because we are using BUFFER for output, we have to reimplement
# pretty much the whole set of buffer editing operations
