#!/usr/local/bin/bash
#
#
#       HetrixTools Server Monitoring Agent
#       version 1.5.9
#       Copyright 2015 - 2020 @  HetrixTools, OpenBSD version by Shawn Holwegner
#       For support, please open a ticket on our website https://hetrixtools.com
#
#
#               DISCLAIMER OF WARRANTY
#
#       The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind, 
#       including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement. 
#       HetrixTools makes no warranty that the Software is free of defects or is suitable for any particular purpose. 
#       In no event shall HetrixTools be responsible for loss or damages arising from the installation or use of the Software, 
#       including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including, 
#       without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses. 
#       The entire risk as to the quality and performance of the Software is borne by you, the user.
#
#

### KNON BUGS: ###
# Non-reentrant.  Runs once.
# Network data collection is not written yet
# Data is all reverse-engineered, so I've mapped, but might have some incorrect info.

##############
## Settings ##
##############

# Set PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/sbin
ScriptPath=$(dirname "${BASH_SOURCE[0]}")

# Agent Version (do not change)
VERSION="1.5.9"

# SID (Server ID - automatically assigned on installation, do not change this)
# DO NOT share this ID with anyone
SID=""

# How frequently should the data be collected (do not modify this, unless instructed to do so)
CollectEveryXSeconds=1
# Runtime, in seconds (do not modify this, unless instructed to do so)
Runtime=60

# Network Interfaces
# * if you leave this setting empty our agent will detect and monitor all of your active network interfaces
# * if you wish to monitor just one interface, fill its name down below (ie: "eth1")
# * if you wish to monitor just some specific interfaces, fill their names below separated by comma (ie: "eth0,eth1,eth2")
NetworkInterfaces="vio0"

# Since we're using a very basic bps service, only hold for a short time
SLEEPTIME="2"

ONETDATA=$(netstat -i -b -n -I $NetworkInterfaces | tail -1 | awk '{print $5, $6}')
INET1=$(echo $ONETDATA | cut -f1 -d\ )
ONET1=$(echo $ONETDATA | cut -f2 -d\ )


sleep $SLEEPTIME

# Check Services
# * separate service names by comma (,) with a maximum of 10 services to be monitored (ie: "ssh,mysql,apache2,nginx")
# * NOTE: this will only check if the service is running, not its functionality
CheckServices="thttpd"

# Check Software RAID Health
# * checks the status/health of any software RAID (mdadm) setup on the server
# * agent must be run as 'root' or privileged user to fetch the RAID status
# * 0 - OFF (default) | 1 - ON
CheckSoftRAID=0

# Check Drive Health
# * checks the health of any found drives on the system
# * requirements: 'S.M.A.R.T.' for HDD/SSD or 'nvme-cli' for NVMe
# * (these do not get installed by our agent, you must install them separately)
# * agent must be run as 'root' or privileged user to use this function
# * 0 - OFF (default) | 1 - ON
CheckDriveHealth=0

# View Running Processes
# * whether or not to record the server's running processes and display them in your HetrixTools dashboard
# * 0 - OFF (default) | 1 - ON
RunningProcesses=0

# Port Connections
# * track network connections to specific ports
# * supports up to 10 different ports, separated by comma (ie: "80,443,3306")
ConnectionPorts=""

################################################
## CAUTION: Do not edit any of the code below ##
################################################

function servicestatus() {
        # Check first via ps
        if (( $(ps aux | grep -v grep | grep $1 | wc -l) > 0 ))
        then
                # Up
                echo "$(echo -ne "$1" | base64),1"
        else
                # No systemctl, declare it down
                echo "$(echo -ne "$1" | base64),0"
        fi
}

# Function used to prepare base64 str for url encoding
function base64prep() {
        str=$1
        str="${str//+/%2B}"
        str="${str//\//%2F}"
        echo $str
}

# Kill any lingering agent processes (there shouldn't be any, the agent should finish its job within ~50 seconds, 
# so when a new cycle starts there shouldn't be any lingering agents around, but just in case, so they won't stack)
HTProcesses=$(ps -eo user=|sort|uniq -c | grep hetrixtools | awk -F " " '{print $1}')
if [ -z "$HTProcesses" ]
then
        HTProcesses=0
fi
if [ "$HTProcesses" -gt 300 ]
then
        ps aux | grep -ie hetrixtools_agent.sh | awk '{print $2}' | xargs kill -9
fi

# Calculate how many times per minute should the data be collected (based on the `CollectEveryXSeconds` setting)
RunTimes=$(($Runtime/$CollectEveryXSeconds))

# Start timers
START=$(date +%s)
tTIMEDIFF=0
M=$(echo `date +%M` | sed 's/^0*//')
if [ -z "$M" ]
then
        M=0
        # Clear the hetrixtools_cron.log every hour
        rm -f $ScriptPath/hetrixtools_cron.log
fi

NetworkInterfacesArray=($(ifconfig -a | grep 'UP' | awk '{print $1}' | cut -f1 -d\:))

OS="$(uname -s)"
OS=$(echo -ne "$OS|$(uname -r)|$RequiresReboot" | base64)
# Get the server uptime
Uptime=$(( $(date +%s) - $(sysctl -n kern.boottime) ))
# Get CPU model
CPUModel=$(sysctl hw.model | sed s,hw.model=,,g | cut -f1 -d\( | base64)
# Get CPU speed (MHz)
CPUSpeed=$(sysctl hw.cpuspeed | sed s,hw.cpuspeed=,,g)
CPUSpeed=$(base64prep $CPUSpeed | base64)
# Get number of cores
CPUCores=$(sysctl hw.ncpu | sed s,hw.ncpu=,,g)
# Calculate average CPU Usage
# XXX - FIXME ---
VMSTAT=$(vmstat | tail -1 )                     
CPU=$(sysctl vm.loadavg | sed s,vm.loadavg=,,g | cut -f1 -d\ )
#CPU=$CPUSpeed
# Calculate IO Wait
# XXX - FIXME ---
IOW=0
IOW=$(echo "$VMSTAT" | awk '{print $16}')
# Get system memory (RAM)
TOP=$(top -b1 | grep "^Memory")
USED_MEM=$(echo "$TOP" | awk -F: '{ print $3 }' | awk -F/ '{ print $2 }' | awk '{ print $1 }' | sed 's/M//g')
FREE_MEM=$(echo "$TOP" | awk -F: '{ print $4 }' | awk '{ print $1 }' | sed 's/M//g')
RAMSize=$(($USED_MEM+$FREE_MEM))
RAM=$(echo | awk "{ print (100 - (($FREE_MEM / $RAMSize)) * 100) }") 
RAMSize=$(sysctl -a | grep hw.physmem | sed s,hw.physmem=,,g | awk '{ print $1 / 1024}')
#
TOP=$(top -b1 | grep "^Memory")
USED_MEM=$(echo "$TOP" | awk -F: '{ print $3 }' | awk -F/ '{ print $2 }' | awk '{ print $1 }' | sed 's/M//g')
FREE_MEM=$(echo "$TOP" | awk -F: '{ print $4 }' | awk '{ print $1 }' | sed 's/M//g')
RAMSize=$(($USED_MEM+$FREE_MEM))
RAM=$(echo | awk "{ print (100 - (($FREE_MEM / $RAMSize)) * 100) }") 
RAMSize=$(sysctl -a | grep hw.physmem | sed s,hw.physmem=,,g | awk '{ print $1 / 1024}')
#
# Get the Swap Size
SWAP=$(swapctl -s -k)
SwapSize=$(echo "$SWAP" | awk '{print $2}')
# Calculate Swap Usage
SwapFree=$(echo "$SWAP" | awk '{print $7}')

Swap=$(echo | awk "{ print (100 - (($SwapFree / $SwapSize)) * 100) }")
# Get all disks usage
DISKs=$(echo -ne $(df -Pk | tail -1 | awk '{ print $(NF)","$2 * 1024","$3 * 1024","$4 * 1024";" }') | gzip -cf | base64 )

DISKs=$(base64prep "$DISKs")
# Get all disks inodes
DISKi=$(echo -ne $(df -ik | awk '$1 ~ /\// {print}' | awk '{ print $(NF)","$2","$3","$4";" }') | gzip -cf | base64)
DISKi=$(base64prep "$DISKi")
RPS1=""
RPS2=""
NETDATA=$(netstat -i -b -n -I $NetworkInterfaces | tail -1 | awk '{print $5, $6}')
INET2=$(echo $NETDATA | cut -f1 -d\ )
ONET2=$(echo $NETDATA | cut -f2 -d\ )

# Compute our basic difference in I/O in bytes.
O=$(($ONET2-$ONET1))
I=$(($INET2-$INET1))

NICS="|"$NetworkInterfaces";"$O";"$I";"
NICS=$(echo -ne "$NICS" | gzip -cf | base64)
NICS=$(base64prep "$NICS")   

# Prepare data
DATA="$OS|$Uptime|$CPUModel|$CPUSpeed|$CPUCores|$CPU|$IOW|$RAMSize|$RAM|$SwapSize|$Swap|$DISKs|$NICS|$ServiceStatusString|$RAID|$DH|$RPS1|$RPS2|$IOPS|$CONN|$DISKi"
POST="v=$VERSION&s=$SID&d=$DATA"
# Save data to file
echo $POST > $ScriptPath/hetrixtools_agent.log

# Post data
wget -t 1 -T 30 -qO- --post-file="$ScriptPath/hetrixtools_agent.log" --no-check-certificate https://sm.hetrixtools.net/ &> /dev/null
