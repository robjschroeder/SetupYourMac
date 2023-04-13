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
# Updated 04.13.2023 @dan-snelson

##################################################

pathToScript=$0
pathToPackage=$1
targetLocation=$2
targetVolume=$3

# Script Variables
scriptVersion="1.2.0"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin/
organizationIdentifier="com.company"
scriptLog="/var/log/${organizationIdentifier}.log"
osVersion=$( sw_vers -productVersion )
osBuild=$( sw_vers -buildVersion )
osMajorVersion=$( echo "${osVersion}" | awk -F '.' '{print $1}' )
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

# Check for / install swiftDialog (Thanks big bunches, @acodega!)
function dialogCheck() {

    # Get the URL of the latest PKG From the Dialog GitHub repo
    dialogURL=$(curl --silent --fail "https://api.github.com/repos/bartreardon/swiftDialog/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")

    # Expected Team ID of the downloaded PKG
    expectedDialogTeamID="PWA5E9TQ59"

    # Check for Dialog and install if not found
    if [ ! -e "/Library/Application Support/Dialog/Dialog.app" ]; then

        updateScriptLog "PRE-FLIGHT CHECK: Dialog not found. Installing..."

        # Create temporary working directory
        workDirectory=$( /usr/bin/basename "$0" )
        tempDirectory=$( /usr/bin/mktemp -d "/private/tmp/$workDirectory.XXXXXX" )

        # Download the installer package
        /usr/bin/curl --location --silent "$dialogURL" -o "$tempDirectory/Dialog.pkg"

        # Verify the download
        teamID=$(/usr/sbin/spctl -a -vv -t install "$tempDirectory/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')

        # Install the package if Team ID validates
        if [[ "$expectedDialogTeamID" == "$teamID" ]]; then

            /usr/sbin/installer -pkg "$tempDirectory/Dialog.pkg" -target /
            sleep 2
            updateScriptLog "PRE-FLIGHT CHECK: swiftDialog version $(/usr/local/bin/dialog --version) installed; proceeding..."

        else

            # Display a so-called "simple" dialog if Team ID fails to validate
            osascript -e 'display dialog "Please advise your Support Representative of the following error:\r\r• Dialog Team ID verification failed\r\r" with title "PreStage SYM: Error" buttons {"Close"} with icon caution'

        fi

        # Remove the temporary working directory when done
        /bin/rm -Rf "$tempDirectory"

    else

        updateScriptLog "PRE-FLIGHT CHECK: swiftDialog version $(/usr/local/bin/dialog --version) found; proceeding..."

    fi

}

if [[ ! -e "/Library/Application Support/Dialog/Dialog.app" ]]; then
    dialogCheck
else
    updateScriptLog "PRE-FLIGHT CHECK: swiftDialog version $(/usr/local/bin/dialog --version) found; proceeding..."
fi

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

# First and most simple test: if enrollment is complete, just run the policy.
# It doesn't matter at that point if someone is logged in or not.
# Don't try to grep a file if it doesn't yet exist.
if  [[ -f /var/log/jamf.log ]]; 
then
	if \$( /usr/bin/grep -q enrollmentComplete /var/log/jamf.log )
	then
		/usr/local/jamf/bin/jamf policy -event ${Trigger}
		exit 0
	fi
fi

# If enrollment isn't complete, and no one has logged in yet, we can wait around indefinitely.
# /var/db/.AppleSetupDone is created after any of these events happen:
# • The MDM solution creates a manaded MDM administrator account
# • The user creates a computer account in Setup Assistant
# That's not enough though, we should wait until they complete Setup Assistant.
# After they make their last Setup Assistant choice,
# /var/db/.AppleDiagnosticsSetupDone is created.
#
until [[ -f /var/db/.AppleDiagnosticsSetupDone ]];
do
	echo "Waiting for someone to complete Setup Assistant."
	sleep 1
done

# At this point, a user is logged in.
# That may have given enough time to complete enrollment.
# Do a quick check to see if enrollment is complete.
#
if  [[ -f /var/log/jamf.log ]]; 
then
	if \$( /usr/bin/grep -q enrollmentComplete /var/log/jamf.log )
	then
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
until [[ -f /var/log/jamf.log ]]
do
	if [[ \$timeoutCounter -ge $enrollmentTimeout ]];
	then
		echo "Gave up waiting for the jamf log to appear."
		exit 1
	else
		echo "Waiting for the jamf log to appear. Timeout counter: \${timeoutCounter} of ${enrollmentTimeout}."
		((timeoutCounter++))
		sleep 1
	fi
done

until ( /usr/bin/grep -q enrollmentComplete /var/log/jamf.log )
do
	if [[ \$timeoutCounter -ge $enrollmentTimeout ]];
	then
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
/usr/local/jamf/bin/jamf policy -event ${Trigger}

ENDOFINSTALLERSCRIPT
) > "${installerScriptPath}"

updateScriptLog "Prestage SYM: ${installerScriptPath} created."
updateScriptLog "Prestage SYM: Setting permissions for ${installerScriptPath}."

chmod 755 "${installerScriptPath}"
chown root:wheel "${installerScriptPath}"

#-----------

# The following creates the LaunchDaemon file 
# that starts the script 
# that waits for Jamf Pro enrollment
# then runs the jamf policy -event command to run your Setup-Your-Mac-via-Dialog.bash script.
# Leave a full return at the end of the content before the last "ENDOFLAUNCHDAEMON" line.
updateScriptLog "Prestage SYM: Creating ${launchDaemonPath}."
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

rm ${tempUtilitiesPath}/${swiftDialogInstallerName}
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
