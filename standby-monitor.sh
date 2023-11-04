#!/bin/bash

source /home/kewko/standby-monitor/.env

check_ping() {
	if ! ping -c2 "$PING_DOMAIN" &> /dev/null; then
		local last_reboot=$(cat /tmp/lastReboot)
		local reboot_delta=$(( $(date +%s) - last_reboot ))
		printf 'Failed to ping %s. Last reboot was %d sec ago.\n' "$PING_DOMAIN" "$reboot_delta" | logger -t standby-monitor -s
		if (( reboot_delta > 10800 )); then
			date +%s > /tmp/lastReboot
			printf 'Rebooting\n' | logger -t standby-monitor -s
			reboot
		fi
	fi
}

check_vpn() {
	last_shakes=$(docker exec wireguard wg show all latest-handshakes | cut -d$'\t' -f 3)
	IFS=' ' read -ra ADDR <<< "$last_shakes"
	for last_shake in "${ADDR[@]}"; do
		echo "Last shake : $last_shake"
		diff=$(( $(date +%s) - last_shake ))
		if (( diff < 600 )); then
			printf 'Sleep inhibited by an active VPN session %d seconds ago\n' "$diff" | logger -t standby-monitor -s
			rm "$IDLE_COUNT_FILE" 2> /dev/null || true
			# exit 0
		fi
	done
}

check_user_session() {
	if who | grep -q .; then
		printf 'Sleep inhibited by an active user session\n' | logger -t standby-monitor -s
		rm "$IDLE_COUNT_FILE" 2> /dev/null || true
		# exit 0
	fi
}

check_inhibit_flag() {
	if (( $INHIBIT == 1 )); then
		printf 'Sleep inhibited by the flag\n' | logger -t standby-monitor -s
		rm "$IDLE_COUNT_FILE" 2> /dev/null || true
		# exit 0
	fi
}

check_plex_activity() {
	local res=$(curl -sf "$PLEX_URL" | jq -e -r '.MediaContainer.size')
	if (( res > 0 )); then
		printf 'Sleep inhibited by Plex activity\n' | logger -t standby-monitor -s
		rm "$IDLE_COUNT_FILE" 2> /dev/null || true
		# exit 0
	fi
}

check_qbittorrent_downloads() {
	local active_downloads=$(curl -sf "http://${QB_URL}:${QB_WEBUI_PORT}/api/v2/torrents/info?filter=downloading" | jq -e -r '.[] | select(.dlspeed < 500) | .hash')
	if [[ -n "$active_downloads" ]]; then
		printf 'Sleep inhibited by active downloads in qBittorrent with download speed less than 500kb/s\n' | logger -t standby-monitor -s
		rm "$IDLE_COUNT_FILE" 2> /dev/null || true
		# exit 0
	fi
}

check_idle() {
	local idle_count=$(cat "$IDLE_COUNT_FILE" 2> /dev/null || true)
	(( idle_count++ ))
	printf 'Been idle %d times\n' "$idle_count" | logger -t standby-monitor -s
	echo "$idle_count" > "$IDLE_COUNT_FILE"
	printf 'Sleeping\n' | logger -t standby-monitor -s
	rm "$IDLE_COUNT_FILE"
	if [ -f /sys/class/rtc/rtc0/wakealarm ]; then
		local wakealarm=$(cat /sys/class/rtc/rtc0/wakealarm)
		if [ -n "$wakealarm" ]; then
			printf 'Next wakeup is scheduled for %s\n' "$(date -d "@$wakealarm")" | logger -t standby-monitor -s
		else
			/usr/sbin/rtcwake -m no -u -t "$(date +\%s -d "$(date +\%D -d '3 hours ago') +1 day 2 hours 59 minutes")"
		fi
	else
		printf 'Cannot access the wakealarm file\n' | logger -t standby-monitor -s -p user.err
	fi
	/usr/sbin/rtcwake -m no -u -t "$(date +\%s -d "$(date) +1 hour")"
	# pm-suspend
}
# sleep $DELAY
check_ping
check_vpn
check_user_session
check_inhibit_flag
check_plex_activity
check_qbittorrent_downloads
check_idle
