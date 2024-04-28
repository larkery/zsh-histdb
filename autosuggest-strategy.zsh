# This query will find the most frequently issued command that is issued in
# the current directory or any subdirectory.
# You can get other behaviours by changing the query.
_zsh_autosuggest_strategy_histdb_top_here() {
    local query="
SELECT
    commands.argv
FROM
    history
LEFT JOIN
    commands
ON
    history.command_id = commands.id
LEFT JOIN
    places
ON
    history.place_id = places.id
WHERE
    places.dir
LIKE
    '$(sql_escape $PWD)%'
AND
    commands.argv
LIKE
    '$(sql_escape $1)%'
GROUP BY
    commands.argv
ORDER BY
    COUNT(commands.argv) DESC
LIMIT 1"
    suggestion=$(_histdb_query "$query")
}

# This will find the most frequently issued command issued exactly in this directory,
# or if there are no matches it will find the most frequently issued command in any directory.
# You could use other fields like the hostname to restrict to suggestions on this host, etc.
_zsh_autosuggest_strategy_histdb_top() {
    local query="
SELECT
    commands.argv
FROM
    history
LEFT JOIN
    commands
ON
    history.command_id = commands.rowid
LEFT JOIN
    places
ON
    history.place_id = places.rowid
WHERE
    commands.argv
LIKE
    '$(sql_escape $1)%'
GROUP BY
    commands.argv,
    places.dir
ORDER BY
    places.dir != '$(sql_escape $PWD)',
    COUNT(commands.argv) DESC
LIMIT 1"
    suggestion=$(_histdb_query "$query")
}

# This query will find the most recently issued command that is issued in
# the current directory or any subdirectory preferring commands in the current session.
_zsh_autosuggest_strategy_histdb_top_here_and_now() {
    local query="
SELECT
    commands.argv
FROM
    history
LEFT JOIN
    commands
ON
    history.command_id = commands.id
LEFT JOIN
    places
ON
    history.place_id = places.id
WHERE
    places.dir
LIKE
    '$(sql_escape $PWD)%'
AND
    commands.argv
LIKE
    '$(sql_escape $1)%'
AND
    history.exit_status = 0
GROUP BY
    commands.argv,
    history.session,
    history.start_time
ORDER BY
    history.session = '$(sql_escape $HISTDB_SESSION)' DESC,
    history.start_time DESC
LIMIT 1"
    suggestion=$(_histdb_query "$query")
}
