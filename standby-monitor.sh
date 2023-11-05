#!/bin/bash
set -euo pipefail
script_filename=$(basename "${BASH_SOURCE[0]}")
script_path=$(realpath "${BASH_SOURCE[0]}")
script_dir=$(dirname $script_path)

# echo $script_filename
# echo $script_path
# echo $script_dir

source "$script_dir/.env"
rerun() {
	echo "Re-running" | logger -t $script_filename -s
    "$script_path" &
	exit 0
}

check_ping() {
	if ! ping -c2 "$PING_DOMAIN" &> /dev/null; then
		local last_reboot=$(cat /tmp/lastReboot)
		local reboot_delta=$(( $(date +%s) - last_reboot ))
		printf 'Failed to ping %s. Last reboot was %d sec ago.' "$PING_DOMAIN" "$reboot_delta" | logger -t $script_filename -s
		if (( reboot_delta > 10800 )); then
			date +%s > /tmp/lastReboot
			printf 'Rebooting' | logger -t $script_filename -s
			reboot
		fi
	fi
}

check_vpn() {
	last_shakes=$(docker exec wireguard wg show all latest-handshakes | cut -d$'\t' -f 3)
	for last_shake in $last_shakes; do
		# echo "Last shake : $last_shake"
		diff=$(( $(date +%s) - last_shake ))
		if (( diff < 600 )); then
			printf 'Sleep inhibited by an active VPN session %d seconds ago' "$diff" | logger -t $script_filename -s
			rerun
		fi
	done
}

check_user_session() {
	if [[ `who | wc -l` -gt 0 ]]; then
		printf 'Sleep inhibited by an active user session' | logger -t $script_filename -s		
		rerun
	fi
}

check_inhibit_flag() {
	if (( "$INHIBIT" == 1 )); then
		printf 'Sleep inhibited by the flag' | logger -t $script_filename -s	
		rerun
	fi
}

check_plex_activity() {
	local res=`curl -s "$PLEX_URL" | grep "MediaContainer size=\"0\"" | wc -l`
	if ! (( res )); then
		printf 'Sleep inhibited by Plex activity' | logger -t $script_filename -s
		rerun
	fi
}

check_downloads() {
	total_download_speed=$(curl -sf "http://${QB_URL}:${QB_PORT}/api/v2/transfer/info" | jq -r '.dl_info_speed')
	if (( total_download_speed > 500000 )); then
		printf 'Sleep inhibited by active downloads with download speed more than 500kb/s' | logger -t $script_filename -s
		rerun
	fi
}

sleep() {

	if [ -f /sys/class/rtc/rtc0/wakealarm ]; then
		local wakealarm=$(cat /sys/class/rtc/rtc0/wakealarm)
		if [ -n "$wakealarm" ]; then
			printf 'Next wakeup is scheduled for %s' "$(date -d "@$wakealarm")" | logger -t $script_filename -s
		else
			/usr/sbin/rtcwake -m no -u -t "$(date +\%s -d "$(date +\%D -d '3 hours ago') +1 day 2 hours 59 minutes")"
		fi
	else
		printf 'Cannot access the wakealarm file' | logger -t $script_filename -s -p user.err
	fi
	/usr/sbin/rtcwake -m no -u -t "$(date +\%s -d "$(date) +1 hour")"
	pm-suspend
	sleep 5
    "$script_path" &
}

# Sleep for the specified delay
echo "Started... Sleeping for $DELAY seconds." | logger -t $script_filename -s
sleep $((DELAY * 60))
check_ping
check_vpn
check_user_session
check_inhibit_flag
check_plex_activity
check_downloads
sleep
