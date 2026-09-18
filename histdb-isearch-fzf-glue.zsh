# histdb-isearch-fzf-glue.zsh
#
# Ties _histdb-isearch (histdb-interactive.zsh) and _fzf_histdb_widget
# (histdb-fzf.zsh) together under one ^r key.
#
# Source it *after* both of those files, e.g.
#
#   source .../histdb-interactive.zsh
#   source .../histdb-fzf.zsh
#   source .../histdb-isearch-fzf-glue.zsh
#
# Behaviour:
#   ^r (normal shell)       enter histdb isearch
#   ^r (isearch, empty)     jump out to the fzf widget
#   ^r (isearch, has text)  move to the previous (older) result
#   ^f (isearch)            jump out to the fzf widget (rebind to taste)
#
# When you accept or quit fzf you return to a normal shell, not back to isearch.

typeset -g _HISTDB_ISEARCH_GOTO_FZF=""
typeset -g _HISTDB_ISEARCH_FZF_QUERY=""

# Bail out of the isearch recursive-edit and remember that we want fzf next.
# NB: use .accept-line, not send-break. send-break sets ZLE's error flag, which
# makes recursive-edit return non-zero but ALSO makes every later `zle ...` call
# in the outer widget a no-op -- so the hand-off to fzf would never run.
# accept-line ends the recursion cleanly (status 0, no error flag).
_histdb-isearch-to-fzf () {
    _HISTDB_ISEARCH_GOTO_FZF=1
    _HISTDB_ISEARCH_FZF_QUERY=${BUFFER}   # carry the typed text into fzf's --query
    zle .accept-line                      # ends recursive-edit, caught in _histdb-isearch
}
zle -N _histdb-isearch-to-fzf

# The key you press while already inside isearch:
#   empty prompt  -> jump to fzf
#   typed prompt  -> previous result
_histdb-isearch-again () {
    if [[ -z ${BUFFER} ]]; then
        _histdb-isearch-to-fzf            # plain function calls are fine here
    else
        _histdb-isearch-up
    fi
}
zle -N _histdb-isearch-again

# The entry widget bound to ^r in the main map. Wraps the stock _histdb-isearch
# and, if we broke out toward fzf, hands off to the fzf widget instead of
# re-entering isearch.
_histdb-isearch-or-fzf () {
    _HISTDB_ISEARCH_GOTO_FZF=""
    zle _histdb-isearch                   # runs its own recursive-edit + cleanup
    if [[ -n ${_HISTDB_ISEARCH_GOTO_FZF} ]]; then
        _HISTDB_ISEARCH_GOTO_FZF=""
        BUFFER=${_HISTDB_ISEARCH_FZF_QUERY}
        CURSOR=$#BUFFER
        zle _fzf_histdb_widget            # accept/quit here returns to a normal shell
    fi
}
zle -N _histdb-isearch-or-fzf

# ^r in the normal shell enters isearch...
bindkey '^r' _histdb-isearch-or-fzf
# ...and ^r inside isearch means "again" (fzf if empty, else previous result).
bindkey -M histdb-isearch '^r' _histdb-isearch-again
# a dedicated isearch->fzf key (change ^f to taste).
bindkey -M histdb-isearch '^f' _histdb-isearch-to-fzf
