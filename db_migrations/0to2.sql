PRAGMA foreign_keys=OFF;
begin transaction;
create table commands_new (id integer primary key autoincrement, argv text, unique(argv) on conflict ignore);
create table places_new   (id integer primary key autoincrement, host text, dir text, unique(host, dir) on conflict ignore);
create table history_new  (id integer primary key autoincrement,
											 session int,
                       command_id int references commands (id),
                       place_id int references places (id),
                       exit_status int,
                       start_time int,
                       duration int);

INSERT INTO commands_new (id, argv) SELECT rowid, argv FROM commands;
INSERT INTO places_new (id, host, dir) SELECT rowid, host, dir FROM places;

INSERT INTO history_new (session, command_id, place_id, exit_status, start_time, duration)
SELECT H.session, C.rowid, P.rowid, H.exit_status, H.start_time, H.duration
FROM history H
LEFT JOIN places P ON H.place_id = P.rowid
LEFT JOIN commands C ON H.command_id = C.rowid;
drop table history;
drop table places;
drop table commands;
ALTER TABLE commands_new RENAME TO commands;
ALTER TABLE places_new RENAME TO places;
ALTER TABLE history_new RENAME TO history;
PRAGMA foreign_key_check ;
PRAGMA user_version=2;
commit;
PRAGMA foreign_keys=ON;
