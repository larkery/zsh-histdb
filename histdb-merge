#!/usr/bin/env zsh

local ancestor=${1:?three databases required}; shift
local ours=${1:?three databases required}; shift
local theirs=${1:?three databases required}

# for reasons I cannot use the encryption filter here.
# most annoying.

sqlite3 "${ours}" <<EOF
ATTACH DATABASE '${theirs}' AS o;
ATTACH DATABASE '${ancestor}' AS a;

-- copy missing commands and places
INSERT INTO commands (argv) SELECT argv FROM o.commands;
INSERT INTO places (host, dir) SELECT host, dir FROM o.places;

-- insert missing history, rewriting IDs
-- could uniquify sessions by host in this way too

INSERT INTO history (session, command_id, place_id, exit_status, start_time, duration)
SELECT HO.session, C.rowid, P.rowid, HO.exit_status, HO.start_time, HO.duration
FROM o.history HO
LEFT JOIN o.places PO ON HO.place_id = PO.rowid
LEFT JOIN o.commands CO ON HO.command_id = CO.rowid
LEFT JOIN commands C ON C.argv = CO.argv
LEFT JOIN places P ON (P.host = PO.host
AND P.dir = PO.dir)
WHERE HO.rowid > (SELECT MAX(rowid) FROM a.history)
;
EOF
