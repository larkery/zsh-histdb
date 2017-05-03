which sqlite3 >/dev/null 2>&1 || return;

typeset -g HISTDB_QUERY=""
typeset -g HISTDB_FILE="${HOME}/.histdb/zsh-history.db"
typeset -g HISTDB_SESSION=""
typeset -g HISTDB_MAX_ROWID=""
typeset -g HISTDB_HOST=""
typeset -g HISTDB_INSTALLED_IN="${(%):-%N}"

sql_escape () {
    sed -e "s/'/''/g" <<< "$@"
}

_histdb_query () {
    sqlite3 "${HISTDB_FILE}" "$@"
    [[ "$?" -ne 0 ]] && echo "error in $@"
}

_histdb_init () {
    if ! [[ -e "${HISTDB_FILE}" ]]; then
        local hist_dir="$(dirname ${HISTDB_FILE})"
        if ! [[ -d "$hist_dir" ]]; then
            mkdir -p -- "$hist_dir"
        fi
        _histdb_query <<-EOF
create table commands (argv text, unique(argv) on conflict ignore);
create table places   (host text, dir text, unique(host, dir) on conflict ignore);
create table history  (session int,
                       command_id int references commands (rowid),
                       place_id int references places (rowid),
                       exit_status int,
                       start_time int,
                       duration int);
EOF
    fi
    if [[ -z "${HISTDB_SESSION}" ]]; then
        HISTDB_HOST="'$(sql_escape ${HOST})'"
        HISTDB_SESSION=$(_histdb_query "select 1+max(session) from history inner join places on places.rowid=history.place_id where places.host = ${HISTDB_HOST}")
        HISTDB_SESSION="${HISTDB_SESSION:-0}"
        readonly HISTDB_SESSION
    fi
}

declare -a _BORING_COMMANDS
_BORING_COMMANDS=("^ls$" "^cd$" "^ " "^histdb" "^top$" "^htop$")

zshaddhistory () {
    local retval=$?
    local cmd="${1[0, -2]}"

    for boring ($_BORING_COMMANDS); do
        if [[ "$cmd" =~ $boring ]]; then
            return 0
        fi
    done

    if [[ $PWD = "$HOME/.history" ]]; then
        return 0
    fi

    local cmd="'$(sql_escape $cmd)'"
    local pwd="'$(sql_escape ${PWD})'"
    local now="${_FINISHED:-$(date +%s)}"
    local started=${_STARTED:-${now}}
    _histdb_init
    if [[ "$cmd" != "''" ]]; then
        _histdb_query \
"insert into commands (argv) values (${cmd});
insert into places   (host, dir) values (${HISTDB_HOST}, ${pwd});
insert into history
  (session, command_id, place_id, exit_status, start_time, duration)
select
  ${HISTDB_SESSION},
  commands.rowid,
  places.rowid,
  ${retval},
  ${started},
  ${now} - ${started}
from
  commands, places
where
  commands.argv = ${cmd} and
  places.host = ${HISTDB_HOST} and
  places.dir = ${pwd}
;"

    fi
    return 0
}

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
            join='places.rowid = history.place_id'
            table=places
            ;;
        cmd)
            field=commands.argv
            join='commands.rowid = history.command_id'
            table=commands
            ;;;
    esac
    _histdb_query -separator "$sep" \
            -header \
            "select count(*) as count, places.host, replace($field, '
', '
$sep$sep') as ${1:-cmd} from history left join commands on history.command_id=commands.rowid left join places on history.place_id=places.rowid group by places.host, $field order by count(*)" |
        column -t -s "$sep"
}

histdb-sync () {
    local hist_dir="$(dirname ${HISTDB_FILE})"
    if [[ -d "$hist_dir" ]]; then
        pushd "$hist_dir"
        if [[ $(git rev-parse --is-inside-work-tree) != "true" ]]; then
            git init
            git config merge.histdb.driver "$(dirname ${HISTDB_INSTALLED_IN})/histdb-merge %O %A %B"
            echo "$(basename ${HISTDB_FILE}) merge=histdb" >> .gitattributes
            git add .gitattributes
            git add "$(basename ${HISTDB_FILE})"
        fi
        git commit -am "history" && git pull --no-edit && git push
        popd
    fi
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
               d h -help \
               s+::=sessions \
               -from:- -until:- -limit:-

    local usage="usage:$0 terms [--host] [--in] [--at] [-s n]+* [--from] [--until] [--limit]
    --host    print the host column and show all hosts (otherwise current host)
    --host x  find entries from host x
    --in      find only entries run in the current dir or below
    --in x    find only entries in directory x or below
    --at      like --in, but excluding subdirectories
    -s n      only show session n
    -d        debug output query that will be run
    --from x  only show commands after date x (sqlite date parser)
    --until x only show commands before date x (sqlite date parser)
    --limit n only show n rows. defaults to $LINES or 25"

    local selcols="session as ses, dir"
    local cols="session, replace(places.dir, '$HOME', '~') as dir"
    local where="not (commands.argv like 'histdb%')"
    local limit="${LINES:-25}"

    if [[ -n "$*" ]]; then
        where="${where} and commands.argv like '%$(sql_escape $@)%'"
    fi

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

    local debug=0
    local opt=""
    for opt ($opts); do
        case $opt in
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
            -h|--help)
                echo "$usage"
                return 0
                ;;
            --limit*)
                limit=${opt#--limit}
                ;;
        esac
    done

    local sep=$'\x1f'
    cols="${cols}, replace(commands.argv, '
', '
$sep$sep$sep') as argv, max(start_time) as max_start"

    local mst="datetime(max_start, 'unixepoch')"
    local dst="datetime('now', 'start of day')"
    local timecol="strftime(case when $mst > $dst then '%H:%M' else '%d/%m' end, max_start, 'unixepoch') as time"

    selcols="${timecol}, ${selcols}, argv as cmd"

    local query="select ${selcols} from (select ${cols}
from
  history
  left join commands on history.command_id = commands.rowid
  left join places on history.place_id = places.rowid
where ${where}
group by history.command_id, history.place_id
order by max_start desc
limit $limit) order by max_start asc"

    if [[ $debug = 1 ]]; then
        echo "$query"
    else
        _histdb_query -header -separator $sep "$query" | column -t -s $sep
    fi
}
