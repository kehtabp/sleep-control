#!/bin/bash
source /home/kewko/standby-monitor/.env
idle_count_file=$IDLE_COUNT_FILE
domain=$PING_DOMAIN
ping $domain -c2 &> /dev/null
if [ $? -ne 0 ]; 
then 
	lastReboot=`cat /tmp/lastReboot`
	rebootDelta=$(expr $(date +%s) - $lastReboot)
	echo Failed to ping $domain. Last reboot was $rebootDelta sec ago. | logger -t standby-monitor -s
	if [ $rebootDelta -gt 10800 ];
	then
  		date +%s > /tmp/lastReboot
		echo Rebooting | logger -t standby-monitor -s
		reboot
	fi
fi 

last_shake=$(docker exec wireguard wg show all latest-handshakes | cut -d$'\t' -f 3)
diff=$(expr $(date +%s) - $last_shake)
if [[ $diff -lt 600 ]]; then
	echo Sleep inhibited by an acive VPN session $diff seconds ago | logger -t standby-monitor -s
	rm $idle_count_file 2> /dev/null
	exit 0
fi

if [[ `who | wc -l` -gt 0 ]]; then
	echo Sleep inhibited by an active user session | logger -t standby-monitor -s
	rm $idle_count_file 2> /dev/null
	exit 0
fi
sleep_set=`curl -s "$INHIBIT_URL"`
inhibit=($sleep_set)
echo ${inhibit[1]}
if [[ ${inhibit[0]} == 1 ]]; then
	echo Sleep inhibited by the flag | logger -t standby-monitor -s
	rm $idle_count_file 2> /dev/null
	exit 0
fi

res=`curl -s "$PLEX_URL" | grep "MediaContainer size=\"0\"" | wc -l`
if [[ $res == "0" ]]; then
	echo Sleep inhibited by Plex activity | logger -t standby-monitor -s
	rm $idle_count_file 2> /dev/null
	exit 0
fi

idle_count=$(cat $idle_count_file 2> /dev/null) || idle_count=0
((idle_count++))
echo Been idle $idle_count times out of  ${inhibit[1]}| logger -t standby-monitor -s
echo $idle_count > $idle_count_file
if [[ $idle_count -ge ${inhibit[1]} ]]; then
	echo Sleeping | logger -t standby-monitor -s
	rm $idle_count_file
	/usr/sbin/rtcwake -m no -u -t $(date +\%s -d "$(date) +1 hour")
	pm-suspend
fi
