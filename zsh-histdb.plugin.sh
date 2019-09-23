PLUGIN_D=$(dirname "$0")
export PATH="${PATH}:${PLUGIN_D}/bin"

source $PLUGIN_D/sqlite-history.zsh
source $PLUGIN_D/histdb-interactive.zsh
autoload -Uz add-zsh-hook
add-zsh-hook precmd histdb-update-outcome
