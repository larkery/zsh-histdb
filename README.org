#+TITLE:ZSH History Database

* News
- 30/06/20 :: Thanks to rolandwalker, add-zsh-hook is used so histdb is a better citizen.
  Thanks to GreenArchon and phiresky the sqlite helper process is terminated on exit better, and the WAL is truncated before doing histdb sync. This should make things behave a bit better. Thanks to gabreal (and others, I think), some things have been changed to ~declare -ga~ which helps when using antigen or somesuch? Thanks to sheperdjerred and fuero there is now a file which might make antigen and oh-my-zsh work.

  There is a *breaking change*, which is that you no longer need to ~add-zsh-hook precmd histdb-update-outcome~ in your rc file. This now happens when you source ~sqlite-history.zsh~.
- 11/03/20 :: Thanks to phiresky (https://github.com/phiresky) history appends within a shell session are performed through a single long-running sqlite process rather than by starting a new process per history append. This reduces contention between shells that are trying to write, as sqlite always fsyncs on exit.
- 29/05/19 :: Thanks to Matthias Bilger (https://github.com/m42e/) a bug has been removed which would have broken the database if the vacuum command were used. Turns out, you can't use rowid as a foreign key unless you've given it a name. As a side-effect your database will need updating, in a non-backwards compatible way, so you'll need to update on all your installations at once if you share a history file.
              Also, it's not impossible that this change will make a problem for someone somewhere, so be careful with this update.

              Also thanks to Matthias, the exit status of long-running commands is handled better.
- 05/04/18 :: I've done a bit of work to make a replacement reverse-isearch function, which is in a usable state now.

              If you want to use it, see the [[Reverse isearch]] section below which now covers it.

- 09/09/17 :: If you have already installed and you want to get the right timings in the database, see the installation section again. Fix to issue #18.

* What is this

This is a small bit of zsh code that stores your history into a sqlite3 database.
It improves on the normal history by storing, for each history command:

- The start and stop times of the command
- The working directory where the command was run
- The hostname of the machine
- A unique per-host session ID, so history from several sessions is not confused
- The exit status of the command

It is also possible to merge multiple history databases together without conflict, so long as all your machines have different hostnames.

* Installation

You will need ~sqlite3~ and the usual coreutils commands installed on your ~PATH~.
To load and activate history recording you need to source ~sqlite-history.zsh~ from your shell in your zsh startup files.

Example for installing in ~$HOME/.oh-my-zsh/custom/plugins/zsh-histdb~ (note that ~oh-my-zsh~ is not required):

#+BEGIN_SRC zsh
mkdir -p $HOME/.oh-my-zsh/custom/plugins/
git clone https://github.com/larkery/zsh-histdb $HOME/.oh-my-zsh/custom/plugins/zsh-histdb
#+END_SRC

Add this to your ~$HOME/.zshrc~:

#+BEGIN_SRC zsh
source $HOME/.oh-my-zsh/custom/plugins/zsh-histdb/sqlite-history.zsh
autoload -Uz add-zsh-hook
#+END_SRC

in your zsh startup files.

** Note for OS X users

Add the following line before you source `sqlite-history.zsh`. See https://github.com/larkery/zsh-histdb/pull/31 for details.

#+BEGIN_SRC zsh
HISTDB_TABULATE_CMD=(sed -e $'s/\x1f/\t/g')
#+END_SRC

** Importing your old history

[[https://github.com/drewis/go-histdbimport][go-histdbimport]] and [[https://github.com/phiresky/ts-histdbimport][ts-histdbimport]] are useful tools for doing this! Note that the imported history will not include metadata such as the working directory or the exit status, since that is not stored in the normal history file format, so queries using ~--in DIR~, etc. will not work as expected.

* Querying history
You can query the history with the ~histdb~ command.
With no arguments it will print one screenful of history on the current host.

With arguments, it will print history lines matching their concatenation.

For wildcards within a history line, you can use the ~%~ character, which is like the shell glob ~*~, so ~histdb this%that~ will match any history line containing ~this~ followed by ~that~ with zero or more characters in-between.

To search on particular hosts, directories, sessions, or time periods, see the help with ~histdb --help~.

You can also run ~histdb-top~ to see your most frequent commands, and ~histdb-top dir~ to show your favourite directory for running commands in, but these commands are really a bit useless.
** Example:

#+BEGIN_SRC text
$ histdb strace
time   ses  dir  cmd
17/03  438  ~    strace conkeror
22/03  522  ~    strace apropos cake
22/03  522  ~    strace -e trace=file s
22/03  522  ~    strace -e trace=file ls
22/03  522  ~    strace -e trace=file cat temp/people.vcf
22/03  522  ~    strace -e trace=file cat temp/gammu.log
22/03  522  ~    run-help strace
24/03  547  ~    man strace
#+END_SRC

These are all the history entries involving ~strace~ in my history.
If there was more than one screenful, I would need to say ~--limit 1000~ or some other large number.
The command does not warn you if you haven't seen all the results.
The ~ses~ column contains a unique session number, so all the ~522~ rows are from the same shell session.

To see all hosts, add ~--host~ /after/ the query terms.
To see a specific host, add ~--host hostname~.
To see all of a specific session say e.g. ~-s 522 --limit 10000~.
** Integration with ~zsh-autosuggestions~

If you use [[https://github.com/zsh-users/zsh-autosuggestions][zsh-autosuggestions]] you can configure it to search the history database instead of the ZSH history file thus:

#+BEGIN_SRC sh
  _zsh_autosuggest_strategy_histdb_top_here() {
      local query="select commands.argv from
  history left join commands on history.command_id = commands.rowid
  left join places on history.place_id = places.rowid
  where places.dir LIKE '$(sql_escape $PWD)%'
  and commands.argv LIKE '$(sql_escape $1)%'
  group by commands.argv order by count(*) desc limit 1"
      suggestion=$(_histdb_query "$query")
  }

  ZSH_AUTOSUGGEST_STRATEGY=histdb_top_here
#+END_SRC

This query will find the most frequently issued command that is issued in the current directory or any subdirectory. You can get other behaviours by changing the query, for example

#+BEGIN_SRC sh
  _zsh_autosuggest_strategy_histdb_top() {
      local query="select commands.argv from
  history left join commands on history.command_id = commands.rowid
  left join places on history.place_id = places.rowid
  where commands.argv LIKE '$(sql_escape $1)%'
  group by commands.argv
  order by places.dir != '$(sql_escape $PWD)', count(*) desc limit 1"
      suggestion=$(_histdb_query "$query")
  }

  ZSH_AUTOSUGGEST_STRATEGY=histdb_top
#+END_SRC

This will find the most frequently issued command issued exactly in this directory, or if there are no matches it will find the most frequently issued command in any directory. You could use other fields like the hostname to restrict to suggestions on this host, etc.
** Reverse isearch
If you want a history-reverse-isearch type feature there is one defined in ~histdb-interactive.zsh~. If you source that file you will get a new widget called _histdb-isearch which you can bind to a key, e.g.

#+BEGIN_SRC sh
source histdb-interactive.zsh
bindkey '^r' _histdb-isearch
#+END_SRC

This is like normal ~history-reverse-isearch~ except:
- The search will start with the buffer contents automatically
- The editing keys are all standard (because it does not really use the minibuffer).

  This means pressing ~C-a~ or ~C-e~ or similar will not exit the search like normal ~history-reverse-isearch~
- The accept key (~RET~) does not cause the command to run immediately but instead lets you edit it

There are also a few extra keybindings:

- ~M-j~ will ~cd~ to the directory for the history entry you're looking at.
  This means you can search for ./run-this-command and then ~M-j~ to go to the right directory before running.
- ~M-h~ will toggle limiting the search to the current host's history.
- ~M-d~ will toggle limiting the search to the current directory and subdirectories' histories
* Database schema
The database lives by default in ~$HOME/.histdb/zsh-history.db~.
You can look in it easily by running ~_histdb_query~, as this actually just fires up sqlite with the database.

For inspiration you can also use ~histdb~ with the ~-d~ argument and it will print the SQL it's running.
* Synchronising history
You should be able to synchronise the history using ~git~; a 3-way merge driver is supplied in ~histdb-merge~.

The 3-way merge will only work properly if all the computers on which you use the repository have different hostnames.

The ~histdb-sync~ function will initialize git in the histdb directory and configure the merge driver for you first time you run it.
Subsequent times it will commit all changes, pull all changes, force a merge, and push all changes back again.
The commit message is useless, so if you find that kind of thing upsetting you will need to fix it.

The reason for using ~histdb-sync~ instead of doing it by hand is that if you are running the git steps in your shell the history database will be changed each command, and so you will never be able to do a pull / merge.
* Completion
None, and I've used the names with underscores to mean something else.
* Pull requests / missing features
Happy to look at changes.
I did at one point have a reverse-isearch thing in here for searching the database interactively, but it didn't really make my life any better so I deleted it.
