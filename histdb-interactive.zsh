typeset -g HISTDB_ISEARCH_N
typeset -g HISTDB_ISEARCH_MATCH

# TODO Show more info about match (n, date, pwd, host)
# TODO Keys to limit match?

# make a keymap for histdb isearch
bindkey -N histdb-isearch main

_histdb_isearch_query () {
    if [[ -z $BUFFER ]]; then
       HISTDB_ISEARCH_MATCH=""
       return
    fi
    local query="select commands.argv from history left join commands
on history.command_id = commands.rowid
where commands.argv like '%$(sql_escape ${BUFFER})%'
group by commands.argv
order by max(history.start_time) desc
limit 1
offset ${HISTDB_ISEARCH_N}"
    HISTDB_ISEARCH_MATCH=$(_histdb_query "$query")
}

_histdb_isearch_display () {
    local prefix="${HISTDB_ISEARCH_MATCH%%${BUFFER}*}"
    local prefix_len="${#prefix}"
    local match_len="${#BUFFER}"
    local match_end=$(( $match_len + $prefix_len ))
    region_highlight=("P${prefix_len} ${match_end} underline")
    PREDISPLAY="${HISTDB_ISEARCH_MATCH}
histdb($HISTDB_ISEARCH_N): "
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
zle -N _histdb-isearch-up
zle -N _histdb-isearch

bindkey -M histdb-isearch '' _histdb-isearch-up
bindkey -M histdb-isearch '^[[A' _histdb-isearch-up

bindkey -M histdb-isearch '' _histdb-isearch-down
bindkey -M histdb-isearch '^[[B' _histdb-isearch-down

# because we are using BUFFER for output, we have to reimplement
# pretty much the whole set of buffer editing operations
