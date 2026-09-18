# fzf-histdb-lite.zsh
#
# Source it *after* zsh-histdb's sqlite-history.zsh.
#
#   list rows      just the command text, fuzzy-match highlighted
#   right column   ~/dir on this host, host:~/dir on other hosts (FQDN stripped)
#   bottom strip   host / date / dir / exit for the highlighted item
#   Alt-h          toggle "current host only"
#   Alt-d          toggle "current directory only"
#   Alt-j          cd to the selected command's directory
#   Enter          put the command in the edit buffer (does not run it)
#   Esc / Ctrl-g   cancel, keeping the typed text
#
# It opens fzf once; the host/dir toggles reload in place. State for a single
# invocation lives in a temp dir so the fzf child processes need nothing set
# in their environment.

# Path to this file, so fzf child shells can re-source it (same trick the
# heavier fzf-histdb.zsh uses).
FZF_HISTDB_LITE_FILE="${(%):-%N}"

# ---------------------------------------------------------------------------
# helpers run both directly and from fzf child shells (via `zsh -c 'source …'`)
# ---------------------------------------------------------------------------

# Re-establish the bits of histdb state a child shell needs, reading them from
# the per-invocation state dir rather than trusting the inherited environment.
_fzf_histdb_load_state () {
  local sd=$1
  typeset -g _fh_width _fh_host _fh_dir _fh_hostname _fh_pwd _fh_home
  typeset -g _fh_sessmode _fh_session _fh_sesshost
  local f
  for f in width host dir hostname pwd home dbfile sessmode session sesshost; do
    [[ -f "$sd/$f" ]] && eval "_fh_$f=\$(<\"\$sd/\$f\")" || eval "_fh_$f="
  done
  _fh_host=${_fh_host:-0}
  _fh_dir=${_fh_dir:-0}
  _fh_sessmode=${_fh_sessmode:-0}
  HISTDB_FILE=$_fh_dbfile
}

# sql-escape a value (mirrors histdb's sql_escape; redefined so we don't depend
# on histdb being sourced in a child shell).
_fzf_histdb_sql_escape () {
  print -r -- ${${1//\'/\'\'}//$'\x00'}
}

# _fzf_histdb_query <sql> — a thin sqlite wrapper for the child shells.
_fzf_histdb_query () {
  sqlite3 -batch -noheader -cmd ".timeout 1000" "${HISTDB_FILE}" "$@"
}

# Emit the fzf rows for the current toggle state.
#   line = <id> \t <command><padding><dim>location</dim>
_fzf_histdb_gen () {
  local sd=$1
  _fzf_histdb_load_state "$sd"

  local where="1"
  if [[ $_fh_host == 1 ]]; then
    where="$where and places.host = '$(_fzf_histdb_sql_escape "$_fh_hostname")'"
  fi
  if [[ $_fh_dir == 1 ]]; then
    where="$where and places.dir like '$(_fzf_histdb_sql_escape "$_fh_pwd")%'"
  fi
  if [[ $_fh_sessmode == 1 && -n $_fh_session ]]; then
    where="$where and history.session = '$(_fzf_histdb_sql_escape "$_fh_session")'"
    where="$where and places.host = '$(_fzf_histdb_sql_escape "$_fh_sesshost")'"
  fi

  local query="
    select
      history.id,
      places.host,
      replace(places.dir, '$(_fzf_histdb_sql_escape "$_fh_home")', '~'),
      ifnull(exit_status, ''),
      replace(replace(replace(commands.argv, char(10), ' '), char(13), ' '), char(9), ' '),
      max(history.start_time)
    from history
      join commands on history.command_id = commands.id
      join places   on history.place_id   = places.id
    where $where
    group by commands.argv
    order by max(history.start_time) desc"

  _fzf_histdb_query -separator $'\x1f' "$query" | awk \
    -F $'\x1f' \
    -v width="$_fh_width" \
    -v self="$_fh_hostname" '
    BEGIN { sub(/\..*/, "", self) }        # compare on short (fqdn-stripped) host
    {
      id   = $1
      host = $2
      dir  = $3
      cmd  = $5

      # short host: strip fqdn
      shost = host
      sub(/\..*/, "", shost)

      loc = (shost == self) ? dir : shost ":" dir

      avail = width - 3                 # leave room for pointer / scrollbar
      line = id "\t" cmd
      pad = avail - length(cmd) - length(loc)
      if (pad >= 1)
        line = line sprintf("%*s", pad, "") "\033[2m" loc "\033[0m"
      print line
    }'
}

# Flip a toggle file (host|dir) between 0 and 1.
_fzf_histdb_toggle () {
  local sd=$1 which=$2
  local cur=$(<"$sd/$which")
  if [[ $cur == 1 ]]; then print -n 0 > "$sd/$which"; else print -n 1 > "$sd/$which"; fi
}

# Toggle "only this row's session". When turning on, capture the session
# (and its host, since session numbers are per-host) of the highlighted id.
_fzf_histdb_toggle_session () {
  local sd=$1 id=$2
  _fzf_histdb_load_state "$sd"
  if [[ $_fh_sessmode == 1 || -z $id ]]; then
    print -n 0 > "$sd/sessmode"
    return
  fi
  local esc="$(_fzf_histdb_sql_escape "$id")"
  local row=$(_fzf_histdb_query -separator $'\x1f' \
    "select history.session, places.host from history join places on history.place_id = places.id where history.id = '$esc'")
  print -rn -- "${row%%$'\x1f'*}" > "$sd/session"
  print -rn -- "${row#*$'\x1f'}"  > "$sd/sesshost"
  print -n 1 > "$sd/sessmode"
}

# Header shown above the list; reflects current toggle state.
_fzf_histdb_header () {
  local sd=$1
  _fzf_histdb_load_state "$sd"
  autoload -U colors && colors

  local hostbit dirbit sessbit
  if [[ $_fh_host == 1 ]]; then
    hostbit="${fg[green]}host:${_fh_hostname%%.*}${reset_color}"
  else
    hostbit="host:all"
  fi
  if [[ $_fh_dir == 1 ]]; then
    dirbit="${fg[green]}dir:${_fh_pwd/#$_fh_home/~}${reset_color}"
  else
    dirbit="dir:all"
  fi
  if [[ $_fh_sessmode == 1 ]]; then
    sessbit="  ${fg[green]}session:${_fh_session}@${_fh_sesshost%%.*}${reset_color}"
  else
    sessbit=""
  fi
  print -r -- "$hostbit  $dirbit$sessbit   —   alt-h host  alt-d dir  alt-s session  ·  alt-j cd  ↵ edit"
}

# Compact detail strip for the highlighted id.
_fzf_histdb_detail () {
  local sd=$1 id=$2
  _fzf_histdb_load_state "$sd"
  [[ -z $id ]] && return
  autoload -U colors && colors

  local esc="$(_fzf_histdb_sql_escape "$id")"
  local query="
    select
      places.host,
      replace(places.dir, '$(_fzf_histdb_sql_escape "$_fh_home")', '~'),
      ifnull(exit_status, 'none'),
      strftime('%d/%m/%Y %H:%M', history.start_time, 'unixepoch', 'localtime'),
      ifnull(duration, '')
    from history
      join places on history.place_id = places.id
    where history.id = '$esc'"

  local -a row
  row=("${(@f)$(_fzf_histdb_query -separator $'\x1f' "$query")}")
  local line=${row[1]}
  local host=${line%%$'\x1f'*}; line=${line#*$'\x1f'}
  local dir=${line%%$'\x1f'*};  line=${line#*$'\x1f'}
  local exit=${line%%$'\x1f'*}; line=${line#*$'\x1f'}
  local date=${line%%$'\x1f'*}; line=${line#*$'\x1f'}
  local secs=${line}

  local exitc
  if [[ $exit == none ]]; then
    exitc="${fg[magenta]}${exit}${reset_color}"
  elif [[ $exit == 0 ]]; then
    exitc="${exit}"
  else
    exitc="${fg[red]}${exit}${reset_color}"
  fi

  print -r -- "Host: ${host%%.*}   Exit: ${exitc}${secs:+   (${secs}s)}"
  print -r -- "Date: ${date}   Dir: ${dir}"
}

# Absolute directory for the selected id (used by Alt-j).
_fzf_histdb_cddir () {
  local sd=$1 id=$2
  _fzf_histdb_load_state "$sd"
  local esc="$(_fzf_histdb_sql_escape "$id")"
  _fzf_histdb_query "select places.dir from history join places on history.place_id = places.id where history.id = '$esc'"
}

# Raw command text for the selected id (newlines preserved).
_fzf_histdb_get () {
  local sd=$1 id=$2
  _fzf_histdb_load_state "$sd"
  local esc="$(_fzf_histdb_sql_escape "$id")"
  _fzf_histdb_query "select commands.argv from history join commands on history.command_id = commands.id where history.id = '$esc'"
}

# ---------------------------------------------------------------------------
# the zle widget
# ---------------------------------------------------------------------------

_fzf_histdb_widget () {
  emulate -L zsh
  setopt localoptions pipefail 2>/dev/null

  _histdb_init

  local sd
  sd=$(mktemp -d "${TMPDIR:-/tmp}/fzf-histdb.XXXXXX") || return
  {
    print -n "$COLUMNS"                        > "$sd/width"
    print -n 0                                 > "$sd/host"
    print -n 0                                 > "$sd/dir"
    print -rn -- "${HOST}"                     > "$sd/hostname"
    print -rn -- "${PWD}"                      > "$sd/pwd"
    print -rn -- "${HOME}"                     > "$sd/home"
    print -rn -- "${HISTDB_FILE}"              > "$sd/dbfile"
    print -n 0                                 > "$sd/sessmode"
    print -n ''                                > "$sd/session"
    print -n ''                                > "$sd/sesshost"

    local f=${(q)FZF_HISTDB_LITE_FILE}
    local q=${(q)sd}
    local src="source $f;"

    local -a fzfopts
    fzfopts=(
      --ansi
      --delimiter=$'\t'
      # Show fields 2.. (hide the id in field 1). Do NOT also set --nth: in
      # fzf 0.72 --nth indices apply to the already-remapped --with-nth view,
      # so --nth=2.. + --with-nth=2.. searches a field that no longer exists
      # and interactively matches nothing (--filter is unaffected, which is why
      # this hid from the doctor). --with-nth alone already scopes search to the
      # shown fields, so the id is neither displayed nor searched.
      --with-nth=2..
      --no-hscroll
      --tiebreak=index
      --highlight-line
      --query="$BUFFER"
      --print-query
      --expect=alt-j
      +m
      --header="$(_fzf_histdb_header "$sd")"
      --preview="zsh -c '${src} _fzf_histdb_detail $q {1}'"
      --preview-window='down,5,border-top,wrap'
      # Neutralise any change:* bind inherited from the user's FZF_DEFAULT_OPTS
      # (e.g. a change:reload from an rg/fzf setup would wipe our list on every
      # keystroke — the classic "no hits when I type" symptom). We just re-home
      # the cursor as you type, which is the sensible default here anyway.
      --bind='change:first'
      # fzf defaults ctrl-k to move-up; restore the emacs kill-line so
      # C-a C-k zaps the query line (navigate with arrows / ctrl-p / ctrl-n).
      --bind='ctrl-k:kill-line'
      # ctrl-d = delete forward char only. fzf's default is delete-char/eof,
      # which aborts on an empty query; use plain delete-char so only C-g / ESC exit.
      --bind='ctrl-d:delete-char'
      --bind="alt-h:execute-silent(zsh -c '${src} _fzf_histdb_toggle $q host')+reload(zsh -c '${src} _fzf_histdb_gen $q')+transform-header(zsh -c '${src} _fzf_histdb_header $q')"
      --bind="alt-d:execute-silent(zsh -c '${src} _fzf_histdb_toggle $q dir')+reload(zsh -c '${src} _fzf_histdb_gen $q')+transform-header(zsh -c '${src} _fzf_histdb_header $q')"
      --bind="alt-s:execute-silent(zsh -c '${src} _fzf_histdb_toggle_session $q {1}')+reload(zsh -c '${src} _fzf_histdb_gen $q')+transform-header(zsh -c '${src} _fzf_histdb_header $q')"
    )

    local -a result
    result=("${(@f)$(_fzf_histdb_gen "$sd" | FZF_DEFAULT_OPTS="$FZF_DEFAULT_OPTS" fzf "${fzfopts[@]}")}")
    local status_code=$?

    local query=${result[1]}
    local key=${result[2]}
    local sel=${result[3]}
    local id=${sel%%$'\t'*}

    if [[ $status_code -ne 0 ]]; then
      # aborted (esc / ctrl-g): keep whatever was typed
      BUFFER=$query
    elif [[ $key == alt-j ]]; then
      local dir=$(_fzf_histdb_cddir "$sd" "$id")
      if [[ -n $dir && -d $dir ]]; then
        builtin cd -- "$dir"
      fi
      BUFFER=$query
    elif [[ -n $id ]]; then
      BUFFER=$(_fzf_histdb_get "$sd" "$id")
    else
      BUFFER=$query
    fi
  } always {
    command rm -rf -- "$sd"
  }

  CURSOR=$#BUFFER
  zle reset-prompt
}

zle     -N   _fzf_histdb_widget
