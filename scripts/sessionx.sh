#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT="$(tmux display-message -p '#S')"
Z_MODE="off"
SESSIONX_HEADER_COMPACT=""

for arg in "$@"; do
	case "$arg" in
		-c|--compact) SESSIONX_HEADER_COMPACT=1 ;;
	esac
done

resolve_session_name() {
	local name="$1"
	local base="${name%-s[0-9]*}"
	if ! tmux has-session -t="$base" 2>/dev/null; then
		echo "$base"
		return
	fi
	local i=1
	while tmux has-session -t="${base}-s${i}" 2>/dev/null; do
		((i++))
	done
	echo "${base}-s${i}"
}

source "$CURRENT_DIR/tmuxinator.sh"
source "$CURRENT_DIR/fzf-marks.sh"
source "$CURRENT_DIR/git-branch.sh"

get_sorted_sessions() {
	last_session=$(tmux display-message -p '#{client_last_session}')
	sessions=$(tmux list-sessions | sed -E 's/:.*$//' | grep -Fxv "$last_session")
	filtered_sessions=$(tmux show-option -gqv @sessionx-_filtered-sessions)
	if [[ -n "$filtered_sessions" ]]; then
	  filtered_and_piped=$(echo "$filtered_sessions" | sed -E 's/,/|/g')
	  sessions=$(echo "$sessions" | grep -Ev "$filtered_and_piped")
	fi
	local sorted
	sorted=$(echo -e "$sessions\n$last_session" | awk '!seen[$0]++')
	echo "$sorted"
}

tmux_option_or_fallback() {
	local option_value
	option_value="$(tmux show-option -gqv "$1")"
	if [ -z "$option_value" ]; then
		option_value="$2"
	fi
	echo "$option_value"
}

input() {
	default_window_mode=$(tmux show-option -gqv @sessionx-_window-mode)
	if [[ "$default_window_mode" == "on" ]]; then
		tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}'
	else
		filter_current_session=$(tmux show-option -gqv @sessionx-_filter-current)
		if [[ "$filter_current_session" == "true" ]]; then
			(get_sorted_sessions | grep -Fxv "$CURRENT") || echo "$CURRENT"
		else
			(get_sorted_sessions) || echo "$CURRENT"
		fi
	fi
}

additional_input() {
	sessions=$(get_sorted_sessions)
	custom_paths=$(tmux show-option -gqv @sessionx-_custom-paths)
	custom_path_subdirectories=$(tmux show-option -gqv @sessionx-_custom-paths-subdirectories)
	if [[ -z "$custom_paths" ]]; then
		echo ""
	else
		clean_paths=$(echo "$custom_paths" | sed -E 's/ *, */,/g' | sed -E 's/^ *//' | sed -E 's/ *$//' | sed -E 's/ /✗/g')
		if [[ "$custom_path_subdirectories" == "true" ]]; then
			paths=$(find ${clean_paths//,/ } -mindepth 1 -maxdepth 1 -type d)
		else
			paths=${clean_paths//,/ }
		fi
		add_path() {
			local path=$1
			if ! grep -q "$(basename "$path")" <<< "$sessions"; then
				echo "$path"
			fi
		}
		export -f add_path
		printf "%s\n" "${paths//,/$IFS}" | xargs -n 1 -P 0 bash -c 'add_path "$@"' _
	fi
}

handle_output() {
	set -- "$(strip_git_branch_info "$*")"
	if [ -d "$*" ]; then
		# No special handling because there isn't a window number or window name present
		# except in unlikely and contrived situations (e.g.
		# "/home/person/projects:0\ bash" could be a path on your filesystem.)
		target=$(echo "$@" | tr -d '\n')
	elif is_fzf-marks_mark "$@" ; then
		# Needs to run before session name mode
		mark=$(get_fzf-marks_mark "$@")
		target=$(get_fzf-marks_target "$@")
	elif echo "$@" | grep ':' >/dev/null 2>&1; then
		# Colon probably delimits session name and window number
		session_name=$(echo "$@" | cut -d: -f1)
		num=$(echo "$@" | cut -d: -f2 | cut -d' ' -f1)
		target=$(echo "${session_name}:${num}" | tr -d '\n')
	else
		# All tokens represent a session name
		target=$(echo "$@" | tr -d '\n')
	fi

	if [[ -z "$target" ]]; then
		exit 0
	fi

	# ctrl-s: create new session with auto-suffix
	if [[ -f /tmp/sessionx_action ]]; then
		local action
		action=$(cat /tmp/sessionx_action)
		rm -f /tmp/sessionx_action
		if [[ "$action" == "newsession" ]]; then
			local sname sdir
			if test -d "$target"; then
				sname="$(basename "$target" | tr -d '.')"
				sdir="$target"
			else
				sname="$target"
				if tmux has-session -t="$sname" 2>/dev/null; then
					sdir=$(tmux display-message -t "$sname" -p '#{session_path}')
				fi
			fi
			local resolved
			resolved=$(resolve_session_name "$sname")
			if [[ -n "$sdir" ]]; then
				tmux new-session -ds "$resolved" -c "$sdir"
			else
				tmux new-session -ds "$resolved"
			fi
			if [[ -n "$SESSIONX_DIRECT" ]]; then
				tmux attach-session -t "$resolved"
			else
				tmux switch-client -t "$resolved"
			fi
			exit 0
		fi
	fi

	if ! tmux has-session -t="$target" 2>/dev/null; then
		if is_tmuxinator_enabled && is_tmuxinator_template "$target"; then
			tmuxinator start "$target"
		elif test -n "$mark"; then
			tmux new-session -ds "$mark" -c "$target"
			target="$mark"
		elif test -d "$target"; then
			d_target="$(basename "$target" | tr -d '.')"
			tmux new-session -ds $d_target -c "$target"
			target=$d_target
		else
			if [[ "$Z_MODE" == "on" ]]; then
				z_target=$(zoxide query "$target")
				tmux new-session -ds "$target" -c "$z_target" -n "$z_target"
			else
				tmux new-session -ds "$target"
			fi
		fi
	fi
	if [[ -n "$SESSIONX_DIRECT" ]]; then
		tmux attach-session -t "$target"
	else
		tmux switch-client -t "$target"
	fi

	exit 0
}

handle_input() {
	INPUT=$(input)
	ADDITIONAL_INPUT=$(additional_input)
	if [[ -n $ADDITIONAL_INPUT ]]; then
		INPUT="$(additional_input)\n$INPUT"
	fi
	bind_back=$(tmux show-option -gqv @sessionx-_bind-back)
	git_branch_mode=$(tmux show-option -gqv @sessionx-_git-branch)
	if [[ "$git_branch_mode" == "on" ]]; then
		BACK="$bind_back:reload(${CURRENT_DIR}/sessions_with_branches.sh)+change-preview(${CURRENT_DIR}/preview.sh {1})"
	else
		BACK="$bind_back:reload(echo -e \"${INPUT// /}\")+change-preview(${CURRENT_DIR}/preview.sh {1})"
	fi
}

run_plugin() {
	Z_MODE=$(tmux_option_or_fallback "@sessionx-zoxide-mode" "off")
	eval $(tmux show-option -gqv @sessionx-_built-args)
	eval $(tmux show-option -gqv @sessionx-_built-fzf-opts)

	# -c/--compact: override header (last --header wins in fzf)
	if [[ -n "$SESSIONX_HEADER_COMPACT" ]]; then
		local ch
		ch=$(tmux show-option -gqv @sessionx-_header-compact)
		if [[ -n "$ch" ]]; then
			args+=(--header "$ch")
		fi
	fi

	handle_input
	args+=(--bind "$BACK")

	git_branch_mode=$(tmux show-option -gqv @sessionx-_git-branch)
	if [[ "$git_branch_mode" == "on" ]]; then
		FZF_LISTEN_PORT=$((RANDOM % 10000 + 20000))
		args+=(--listen "localhost:$FZF_LISTEN_PORT")
		args+=(--tiebreak=begin)
		"${CURRENT_DIR}/sessions_with_branches.sh" "$FZF_LISTEN_PORT" &
	fi

	FZF_BUILTIN_TMUX=$(tmux show-option -gqv @sessionx-_fzf-builtin-tmux)
	if [[ -n "$SESSIONX_DIRECT" ]]; then
		# Direct mode: plain fzf, filter out -p/--tmux size args
		local direct_args=()
		local skip_next=false
		for arg in "${args[@]}"; do
			if $skip_next; then skip_next=false; continue; fi
			if [[ "$arg" == "-p" || "$arg" == "--tmux" ]]; then skip_next=true; continue; fi
			direct_args+=("$arg")
		done
		RESULT=$(echo -e "${INPUT}" | sed -E 's/✗/ /g' | fzf "${fzf_opts[@]}" "${direct_args[@]}" | tail -n1)
	elif [[ "$FZF_BUILTIN_TMUX" == "on" ]]; then
		RESULT=$(echo -e "${INPUT}" | sed -E 's/✗/ /g' | fzf "${fzf_opts[@]}" "${args[@]}" | tail -n1)
	else
		RESULT=$(echo -e "${INPUT}" | sed -E 's/✗/ /g' | fzf-tmux "${fzf_opts[@]}" "${args[@]}" | tail -n1)
	fi
}

rm -f /tmp/sessionx_action
run_plugin
handle_output "$RESULT"
