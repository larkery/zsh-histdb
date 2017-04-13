typeset -g _STARTED
typeset -g _FINISHED

_start_timer () {
    _STARTED=$(date +%s)
    _FINISHED=$_STARTED
}

_stop_timer () {
    _FINISHED=$(date +%s)
}
