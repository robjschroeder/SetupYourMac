#!/bin/zsh
## postinstall

# Postinstall script which creates the following:
# - A LaunchDaemon that starts a separate script to run a Jamf Pro policy command
# - A script to wait for Jamf Pro enrollment to complete then triggers Setup Your Mac
# - A script that is designed to be called by a Jamf Pro policy to unload the Launch Daemon
# -- and then remove the LaunchDaemon and script
# - Creates "/Library/Application Support/Dialog/Dialog.png" from Self Service's custom icon (thanks, @meschwartz!) 
#
# Created 01.16.2023 @robjschroeder
# Updated 03.11.2023 @robjschroeder
# Updated 04.13.2023 @dan-snelson -- version 1.2.0
# Updated 05.09.2023 @robjschroeder -- version 1.2.1
#	- Removed function dialogCheck, will rely on Setup Your Mac to download the latest version of swiftDialog
#	+ Renamed script for alignment with Setup Your Mac
# Updated 05.16.2023 @robjschroeder -- version 1.2.2
#       + Added record of OS version and build to log
#       + Added extra 'If' to look for touch file in case the jamf.log gets wiped. This is helpful if SYM has a minimum
#       build requirement before it can complete. (Thanks @drtaru!!)

##################################################

pathToScript=$0
pathToPackage=$1
targetLocation=$2
targetVolume=$3

# Script Variables
scriptVersion="1.2.2"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin/
organizationIdentifier="com.company"
scriptLog="/var/log/${organizationIdentifier}.log"
osVersion=$( sw_vers -productVersion )
osBuild=$( sw_vers -buildVersion )
tempUtilitiesPath="/usr/local/SYM-enrollment"

# Jamf Pro Policy Trigger
Trigger="symStart"

# After Setup Assistant exits, if jamf enrollment isn't complete,
# this is how many seconds to wait complete before exiting with an error:
enrollmentTimeout="120"

# One approach is to use the following locations and files:
# LaunchDaemon: 
#	/Library/LaunchDaemons/${organizationIdentifier}.sym-prestarter.plist

# Temporary folder for the installer and scripts:
#	/usr/local/SYM-enrollment

# Scripts:
#	${tempUtilitiesPath}/${organizationIdentifier}.sym-prestarter-installer.zsh
#	${tempUtilitiesPath}/${organizationIdentifier}.sym-prestarter-uninstaller.zsh

# Create temp folder for scripts
if [[ ! -d ${tempUtilitiesPath} ]]; then
	mkdir ${tempUtilitiesPath}
fi

# Client-side logging
if [[ ! -f "${scriptLog}" ]]; then
	touch "${scriptLog}"
fi

# Client-side Script Logging Function (Thanks @dan-snelson!!)
function updateScriptLog() {
	echo -e "$( date +%Y-%m-%d\ %H:%M:%S ) - ${1}" | tee -a "${scriptLog}"
}

# Start Logging
updateScriptLog "\n###\n# PreStage SYM (${scriptVersion})\n# https://techitout.xyz/\n###\n"
updateScriptLog "PRE-FLIGHT CHECK: Initiating ..."

# This script must be run as root or via Jamf Pro.
# The resulting Script and LaunchDaemon will be run as root.
if [[ $(id -u) -ne 0 ]]; then
	updateScriptLog "PRE-FLIGHT CHECK: This script must be run as root; exiting."
	exit 1
fi

# Record OS Information into log
updateScriptLog "PRE-FLIGHT CHECK: Running macOS $osVersion build $osBuild"

# Pre-flight Checks Complete
updateScriptLog "PRE-FLIGHT CHECK: Complete"

# Script and Launch Daemon/Agent variables
installerBaseString=${organizationIdentifier}.sym-prestarter
installerScriptName=${installerBaseString}-installer.zsh
installerScriptPath=${tempUtilitiesPath}/${installerScriptName}
uninstallerScriptName=${installerBaseString}-uninstaller.zsh
uninstallerScriptPath=${tempUtilitiesPath}/${uninstallerScriptName}
launchDaemonName=${installerBaseString}.plist
launchDaemonPath="/Library/LaunchDaemons"/${launchDaemonName}

# The following creates a script that triggers the swiftDialog setup your mac script to start. 
# Leave a full return at the end of the content before the last "ENDOFINSTALLERSCRIPT" line.
updateScriptLog "PreStage SYM: Creating ${installerScriptPath}"

(
cat <<ENDOFINSTALLERSCRIPT
#!/bin/zsh

# Check to see if sym-triggered file exists, then proceed calling SYM here
if [[ -f ${tempUtilitiesPath}/.sym-triggered ]]; then
	echo "SYM was previously triggered, lets continue..."
	/usr/local/jamf/bin/jamf policy -event ${Trigger}
	exit 0
fi

# First and most simple test: if enrollment is complete, just run the policy.
# It doesn't matter at that point if someone is logged in or not.
# Don't try to grep a file if it doesn't yet exist.
if  [[ -f /var/log/jamf.log ]]; then
	if \$( /usr/bin/grep -q enrollmentComplete /var/log/jamf.log ); then
		touch ${tempUtilitiesPath}/.sym-triggered
		/usr/local/jamf/bin/jamf policy -event ${Trigger}
		exit 0
	fi
fi

# If enrollment isn't complete, and no one has logged in yet, we can wait around indefinitely.
# /var/db/.AppleSetupDone is created after any of these events happen:
# • The MDM solution creates a managed MDM administrator account
# • The user creates a computer account in Setup Assistant
# That's not enough though, we should wait until they complete Setup Assistant.
# After they make their last Setup Assistant choice,
# /var/db/.AppleDiagnosticsSetupDone is created.
#
until [[ -f /var/db/.AppleDiagnosticsSetupDone ]]; do
	echo "Waiting for someone to complete Setup Assistant."
	sleep 1
done

# At this point, a user is logged in.
# That may have given enough time to complete enrollment.
# Do a quick check to see if enrollment is complete.
#
if  [[ -f /var/log/jamf.log ]]; then
	if \$( /usr/bin/grep -q enrollmentComplete /var/log/jamf.log ); then
		touch ${tempUtilitiesPath}/.sym-triggered
		/usr/local/jamf/bin/jamf policy -event ${Trigger}
		exit 0
	fi
fi

# At this point, a user is logged in, but enrollment isn't complete.
# Display a message that they need to wait, but don't display it forever.
# Set up a temporary message for swiftDialog to use
# Assume that because we waited for /var/db/.AppleDiagnosticsSetupDone to exist,
# we are logged in as a real user instead of _mbsetutp user.

timeoutCounter=0
until [[ -f /var/log/jamf.log ]]; do
	if [[ \$timeoutCounter -ge $enrollmentTimeout ]]; then
		echo "Gave up waiting for the jamf log to appear."
		exit 1
	else
		echo "Waiting for the jamf log to appear. Timeout counter: \${timeoutCounter} of ${enrollmentTimeout}."
		((timeoutCounter++))
		sleep 1
	fi
done

until ( /usr/bin/grep -q enrollmentComplete /var/log/jamf.log ); do
	if [[ \$timeoutCounter -ge $enrollmentTimeout ]]; then
		echo "Gave up waiting for enrollment to complete."
		exit 1
	else
		echo "Waiting for jamf enrollment to complete: Timeout counter: \${timeoutCounter} of ${enrollmentTimeout}."
		((timeoutCounter++))
		sleep 1
	fi
done

# At this point, we can assume:
# 1. A real user is logged in
# 2. jamf enrollment is complete

# Run the policy to call the  swiftDialog setup your mac script.
touch ${tempUtilitiesPath}/.sym-triggered
/usr/local/jamf/bin/jamf policy -event ${Trigger}

ENDOFINSTALLERSCRIPT
) > "${installerScriptPath}"

updateScriptLog "PreStage SYM: ${installerScriptPath} created."
updateScriptLog "PreStage SYM: Setting permissions for ${installerScriptPath}."

chmod 755 "${installerScriptPath}"
chown root:wheel "${installerScriptPath}"

#-----------

# The following creates the LaunchDaemon file 
# that starts the script 
# that waits for Jamf Pro enrollment
# then runs the jamf policy -event command to run your Setup-Your-Mac-via-Dialog.bash script.
# Leave a full return at the end of the content before the last "ENDOFLAUNCHDAEMON" line.
updateScriptLog "PreStage SYM: Creating ${launchDaemonPath}."
(
cat <<ENDOFLAUNCHDAEMON
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${launchDaemonName}</string>
	<key>RunAtLoad</key>
	<true/>
	<key>UserName</key>
	<string>root</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/zsh</string>
		<string>${installerScriptPath}</string>
	</array>
	<key>StandardErrorPath</key>
	<string>/var/tmp/${installerScriptName}.err.log</string>
	<key>StandardOutPath</key>
	<string>/var/tmp/${installerScriptName}.out.log</string>
</dict>
</plist>

ENDOFLAUNCHDAEMON
)  > "${launchDaemonPath}"

updateScriptLog "PreStage SYM: Setting permissions for ${launchDaemonPath}."
chmod 644 "${launchDaemonPath}"
chown root:wheel "${launchDaemonPath}"

updateScriptLog "PreStage SYM: Loading ${launchDaemonName}."
launchctl load "${launchDaemonPath}"

#-----------

# The following creates the script to uninstall the LaunchDaemon and installer script.
# You can create a Jamf Pro policy with the following characteristics:
# General settings:
# --Name: Cleanup SYM Installers
# --Trigger: Custom Trigger: cleanup-sym-preinstaller
# --Scope: All Computers
# --Frequency: Once per Computer
# Files and Processes settings:
# --Execute Command: Whatever your $uninstallerScriptPath is set to.
#
# In your Setup-Your-Mac-via-Dialog.sh script, include the policy near the end of your policy array.
#
# Leave a full return at the end of the content before the last "ENDOFUNINSTALLERSCRIPT" line.
updateScriptLog "PreStage SYM: Creating ${uninstallerScriptPath}."
(
cat <<ENDOFUNINSTALLERSCRIPT
#!/bin/zsh
# This is meant to be called by a Jamf Pro policy via trigger
# Near the end of your JSON policy array in your swiftDialog setup your mac script

rm ${installerScriptPath}

# Note that if you unload the LaunchDaemon this will immediately kill the setup your mac script script
# Just remove the underlying plist file, and the LaunchDaemon will not run after next reboot/login.

rm ${launchDaemonPath}
rm ${uninstallerScriptPath}
rmdir ${tempUtilitiesPath}
rm /var/tmp/${installerScriptName}.err.log
rm /var/tmp/${installerScriptName}.out.log

ENDOFUNINSTALLERSCRIPT
) > "${uninstallerScriptPath}"

updateScriptLog "PreStage SYM: Setting permissions for ${uninstallerScriptPath}."
chmod 777 "${uninstallerScriptPath}"
chown root:wheel "${uninstallerScriptPath}"

updateScriptLog "PreStage SYM: Complete."

exit 0		## Success
exit 1		## Failure
