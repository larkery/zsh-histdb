which sqlite3 >/dev/null 2>&1 || return;

zmodload zsh/system # for sysopen
zmodload -F zsh/stat b:zstat # just zstat
autoload -U add-zsh-hook

typeset -g HISTDB_QUERY=""
if [[ -z ${HISTDB_FILE} ]]; then
    typeset -g HISTDB_FILE="${HOME}/.histdb/zsh-history.db"
else
    typeset -g HISTDB_FILE
fi

typeset -g HISTDB_INODE=""
typeset -g HISTDB_SESSION=""
typeset -g HISTDB_HOST=""
typeset -g HISTDB_INSTALLED_IN="${(%):-%N}"



sql_escape () {
    sed -e "s/'/''/g" <<< "$@" | tr -d '\000'
}

_histdb_query () {
    sqlite3 -cmd ".timeout 1000" "${HISTDB_FILE}" "$@"
    [[ "$?" -ne 0 ]] && echo "error in $@"
}

_histdb_stop_sqlite_pipe () {
    if [[ -n $HISTDB_FD ]]; then
        if print -nu$HISTDB_FD; then
            exec {HISTDB_FD}>&-;  # https://stackoverflow.com/a/22794374/2639190
        fi
    fi
    # Sometimes, it seems like closing the fd does not terminate the
    # sqlite batch process, so here is a horrible fallback.
    # if [[ -n $HISTDB_SQLITE_PID ]]; then
    #     ps -o args= -p $HISTDB_SQLITE_PID | read -r args
    #     if [[ $args == "sqlite3 -batch ${HISTDB_FILE}" ]]; then
    #         kill -TERM $HISTDB_SQLITE_PID
    #     fi
    # fi
}

add-zsh-hook zshexit _histdb_stop_sqlite_pipe

_histdb_start_sqlite_pipe () {
    local PIPE=$(mktemp -u)
    setopt local_options no_notify no_monitor
    mkfifo $PIPE
    sqlite3 -batch "${HISTDB_FILE}" < $PIPE >/dev/null &|
    sysopen -w -o cloexec -u HISTDB_FD -- $PIPE
    command rm $PIPE
    HISTDB_INODE=$(zstat +inode ${HISTDB_FILE})
}

_histdb_query_batch () {
    local CUR_INODE=$(zstat +inode ${HISTDB_FILE})
    if [[ $CUR_INODE != $HISTDB_INODE ]]; then
        _histdb_stop_sqlite_pipe
        _histdb_start_sqlite_pipe
    fi
    cat >&$HISTDB_FD
    echo ';' >&$HISTDB_FD # make sure last command is executed
}

_histdb_init () {
    if [[ -n "${HISTDB_SESSION}" ]]; then
        return
    fi
    
    if ! [[ -e "${HISTDB_FILE}" ]]; then
        local hist_dir="$(dirname ${HISTDB_FILE})"
        if ! [[ -d "$hist_dir" ]]; then
            mkdir -p -- "$hist_dir"
        fi
        _histdb_query <<-EOF
create table commands (id integer primary key autoincrement, argv text, unique(argv) on conflict ignore);
create table places   (id integer primary key autoincrement, host text, dir text, unique(host, dir) on conflict ignore);
create table history  (id integer primary key autoincrement,
                       session int,
                       command_id int references commands (id),
                       place_id int references places (id),
                       exit_status int,
                       start_time int,
                       duration int);
PRAGMA user_version = 2;
EOF
    fi
    if [[ -z "${HISTDB_SESSION}" ]]; then
        $(dirname ${HISTDB_INSTALLED_IN})/histdb-migrate "${HISTDB_FILE}"
        HISTDB_HOST="'$(sql_escape ${HOST})'"
        HISTDB_SESSION=$(_histdb_query "select 1+max(session) from history inner join places on places.id=history.place_id where places.host = ${HISTDB_HOST}")
        HISTDB_SESSION="${HISTDB_SESSION:-0}"
        readonly HISTDB_SESSION
    fi

    _histdb_start_sqlite_pipe
    _histdb_query_batch >/dev/null <<EOF
create index if not exists hist_time on history(start_time);
create index if not exists place_dir on places(dir);
create index if not exists place_host on places(host);
create index if not exists history_command_place on history(command_id, place_id);
PRAGMA journal_mode = WAL;
PRAGMA synchronous=normal;
EOF
}

declare -ga _BORING_COMMANDS
_BORING_COMMANDS=("^ls$" "^cd$" "^ " "^histdb" "^top$" "^htop$")

if [[ -z "${HISTDB_TABULATE_CMD[*]:-}" ]]; then
    declare -ga HISTDB_TABULATE_CMD
    HISTDB_TABULATE_CMD=(column -t -s $'\x1f')
fi

_histdb_update_outcome () {
    local retval=$?
    local finished=$(date +%s)
    [[ -z "${HISTDB_SESSION}" ]] && return

    _histdb_init
    _histdb_query_batch <<EOF &|
update history set 
      exit_status = ${retval}, 
      duration = ${finished} - start_time
where id = (select max(id) from history) and 
      session = ${HISTDB_SESSION} and
      exit_status is NULL;
EOF
}

_histdb_addhistory () {
    local cmd="${1[0, -2]}"

    for boring in "${_BORING_COMMANDS[@]}"; do
        if [[ "$cmd" =~ $boring ]]; then
            return 0
        fi
    done

    local cmd="'$(sql_escape $cmd)'"
    local pwd="'$(sql_escape ${PWD})'"
    local started=$(date +%s)
    _histdb_init

    if [[ "$cmd" != "''" ]]; then
        _histdb_query_batch <<EOF &|
insert into commands (argv) values (${cmd});
insert into places   (host, dir) values (${HISTDB_HOST}, ${pwd});
insert into history
  (session, command_id, place_id, start_time)
select
  ${HISTDB_SESSION},
  commands.id,
  places.id,
  ${started}
from
  commands, places
where
  commands.argv = ${cmd} and
  places.host = ${HISTDB_HOST} and
  places.dir = ${pwd}
;
EOF
    fi
    return 0
}

add-zsh-hook zshaddhistory _histdb_addhistory
add-zsh-hook precmd _histdb_update_outcome

histdb-top () {
    _histdb_init
    local sep=$'\x1f'
    local field
    local join
    local table
    1=${1:-cmd}
    case "$1" in
        dir)
            field=places.dir
            join='places.id = history.place_id'
            table=places
            ;;
        cmd)
            field=commands.argv
            join='commands.id = history.command_id'
            table=commands
            ;;;
    esac
    _histdb_query -separator "$sep" \
            -header \
            "select count(*) as count, places.host, replace($field, '
', '
$sep$sep') as ${1:-cmd} from history left join commands on history.command_id=commands.id left join places on history.place_id=places.id group by places.host, $field order by count(*)" | \
        "${HISTDB_TABULATE_CMD[@]}"
}

histdb-sync () {
    _histdb_init

    # this ought to apply to other readers?
    echo "truncating WAL"
    echo 'pragma wal_checkpoint(truncate);' | _histdb_query_batch
    
    local hist_dir="$(dirname ${HISTDB_FILE})"
    if [[ -d "$hist_dir" ]]; then
        pushd "$hist_dir"
        if [[ $(git rev-parse --is-inside-work-tree) != "true" ]] || [[ "$(git rev-parse --show-toplevel)" != "$(pwd -P)" ]]; then
            git init
            git config merge.histdb.driver "$(dirname ${HISTDB_INSTALLED_IN})/histdb-merge %O %A %B"
            echo "$(basename ${HISTDB_FILE}) merge=histdb" | tee -a .gitattributes &>-
            git add .gitattributes
            git add "$(basename ${HISTDB_FILE})"
        fi
        git commit -am "history" && git pull --no-edit && git push
        popd
    fi

    echo 'pragma wal_checkpoint(passive);' | _histdb_query_batch
}

histdb () {
    _histdb_init
    local -a opts
    local -a hosts
    local -a indirs
    local -a atdirs
    local -a sessions

    zparseopts -E -D -a opts \
               -host+::=hosts \
               -in+::=indirs \
               -at+::=atdirs \
               -forget \
               -detail \
               -sep:- \
               -exact \
               d h -help \
               s+::=sessions \
               -from:- -until:- -limit:- \
               -status:- -desc

    local usage="usage:$0 terms [--host] [--in] [--at] [-s n]+* [--from] [--until] [--limit] [--forget] [--sep x] [--detail]
    --desc     reverse sort order of results
    --host     print the host column and show all hosts (otherwise current host)
    --host x   find entries from host x
    --in       find only entries run in the current dir or below
    --in x     find only entries in directory x or below
    --at       like --in, but excluding subdirectories
    -s n       only show session n
    -d         debug output query that will be run
    --detail   show details
    --forget   forget everything which matches in the history
    --exact    don't match substrings
    --sep x    print with separator x, and don't tabulate
    --from x   only show commands after date x (sqlite date parser)
    --until x  only show commands before date x (sqlite date parser)
    --limit n  only show n rows. defaults to $LINES or 25
    --status x only show rows with exit status x. Can be 'error' to find all nonzero."

    local selcols="session as ses, dir"
    local cols="session, replace(places.dir, '$HOME', '~') as dir"
    local where="1"
    if [[ -p /dev/stdout ]]; then
        local limit=""
    else
        local limit="${$((LINES - 4)):-25}"
    fi

    local forget="0"
    local exact=0

    if (( ${#hosts} )); then
        local hostwhere=""
        local host=""
        for host ($hosts); do
            host="${${host#--host}#=}"
            hostwhere="${hostwhere}${host:+${hostwhere:+ or }places.host='$(sql_escape ${host})'}"
        done
        where="${where}${hostwhere:+ and (${hostwhere})}"
        cols="${cols}, places.host as host"
        selcols="${selcols}, host"
    else
        where="${where} and places.host=${HISTDB_HOST}"
    fi

    if (( ${#indirs} + ${#atdirs} )); then
        local dirwhere=""
        local dir=""
        for dir ($indirs); do
            dir="${${${dir#--in}#=}:-$PWD}"
            dirwhere="${dirwhere}${dirwhere:+ or }places.dir like '$(sql_escape $dir)%'"
        done
        for dir ($atdirs); do
            dir="${${${dir#--at}#=}:-$PWD}"
            dirwhere="${dirwhere}${dirwhere:+ or }places.dir = '$(sql_escape $dir)'"
        done
        where="${where}${dirwhere:+ and (${dirwhere})}"
    fi

    if (( ${#sessions} )); then
        local sin=""
        local ses=""
        for ses ($sessions); do
            ses="${${${ses#-s}#=}:-${HISTDB_SESSION}}"
            sin="${sin}${sin:+, }$ses"
        done
        where="${where}${sin:+ and session in ($sin)}"
    fi

    local sep=$'\x1f'
    local orderdir='asc'
    local debug=0
    local opt=""
    for opt ($opts); do
        case $opt in
            --desc)
                orderdir='desc'
                ;;
            --sep*)
                sep=${opt#--sep}
                ;;
            --from*)
                local from=${opt#--from}
                case $from in
                    -*)
                        from="datetime('now', '$from')"
                        ;;
                    today)
                        from="datetime('now', 'start of day')"
                        ;;
                    yesterday)
                        from="datetime('now', 'start of day', '-1 day')"
                        ;;
                esac
                where="${where} and datetime(start_time, 'unixepoch') >= $from"
                ;;
            --status*)
                local xstatus=${opt#--status}
                case $xstatus in
                    <->)
                        where="${where} and exit_status = $xstatus"
                        ;;
                        error)
                        where="${where} and exit_status <> 0"
                        ;;
                esac
                ;;
            --until*)
                local until=${opt#--until}
                case $until in
                    -*)
                        until="datetime('now', '$until')"
                        ;;
                    today)
                        until="datetime('now', 'start of day')"
                        ;;
                    yesterday)
                        until="datetime('now', 'start of day', '-1 day')"
                        ;;
                esac
                where="${where} and datetime(start_time, 'unixepoch') <= $until"
                ;;
            -d)
                debug=1
                ;;
            --detail)
                cols="${cols}, exit_status, duration "
                selcols="${selcols}, exit_status as [?],duration as secs "
                ;;
            -h|--help)
                echo "$usage"
                return 0
                ;;
            --forget)
                forget=1
                ;;
            --exact)
                exact=1
                ;;
            --limit*)
                limit=${opt#--limit}
                ;;
        esac
    done

    if [[ -n "$*" ]]; then
        if [[ $exact -eq 0 ]]; then
            where="${where} and commands.argv glob '*$(sql_escape $@)*'"
        else
            where="${where} and commands.argv = '$(sql_escape $@)'"
        fi
    fi

    if [[ $forget -gt 0 ]]; then
        limit=""
    fi
    local seps=$(echo "$cols" | tr -c -d ',' | tr ',' $sep)
    cols="${cols}, replace(commands.argv, '
', '
$seps') as argv, max(start_time) as max_start"

    local mst="datetime(max_start, 'unixepoch')"
    local dst="datetime('now', 'start of day')"
    local timecol="strftime(case when $mst > $dst then '%H:%M' else '%d/%m' end, max_start, 'unixepoch', 'localtime') as time"

    selcols="${timecol}, ${selcols}, argv as cmd"

    local r_order="asc"
    if [[ $orderdir == "asc" ]]; then
        r_order="desc"
    fi
    
    local query="select ${selcols} from (select ${cols}
from
  commands 
  join history on history.command_id = commands.id
  join places on history.place_id = places.id
where ${where}
group by history.command_id, history.place_id
order by max_start ${r_order}
${limit:+limit $limit}) order by max_start ${orderdir}"

    ## min max date?
    local count_query="select count(*) from (select ${cols}
from
  commands
  join history on history.command_id = commands.id
  join places  on history.place_id = places.id
where ${where}
group by history.command_id, history.place_id
order by max_start desc) order by max_start ${orderdir}"

    if [[ $debug = 1 ]]; then
        echo "$query"
    else
        local count=$(_histdb_query "$count_query")
        if [[ -p /dev/stdout ]]; then
            buffer() {
                ## this runs out of memory for big files I think perl -e 'local $/; my $stdin = <STDIN>; print $stdin;'
                temp=$(mktemp)
                cat >! "$temp"
                cat -- "$temp"
                rm -f -- "$temp"
            }
        else
            buffer() {
                cat
            }
        fi
        if [[ $sep == $'\x1f' ]]; then
            _histdb_query -header -separator $sep "$query" | iconv -f utf-8 -t utf-8 -c | "${HISTDB_TABULATE_CMD[@]}" | buffer
        else
            _histdb_query -header -separator $sep "$query" | buffer
        fi
        [[ -n $limit ]] && [[ $limit -lt $count ]] && echo "(showing $limit of $count results)"
    fi

    if [[ $forget -gt 0 ]]; then
        read -q "REPLY?Forget all these results? [y/n] "
        if [[ $REPLY =~ "[yY]" ]]; then
            _histdb_query "delete from history where
history.id in (
select history.id from
history
  left join commands on history.command_id = commands.id
  left join places on history.place_id = places.id
where ${where})"
            _histdb_query "delete from commands where commands.id not in (select distinct history.command_id from history)"
        fi
    fi
}
