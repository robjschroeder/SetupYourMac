#!/bin/zsh
## postinstall

pathToScript=$0
pathToPackage=$1
targetLocation=$2
targetVolume=$3

# Optionally replace the value of this variable with the name of your organization.
organizationIdentifier=com.lululemon
waitMessage="Please wait a moment while your Mac completes enrolling with your organization's mobile device management solution."
#
# After Setup Assistant exits, if jamf enrollment isn't complete,
# this is how many seconds to wait complete before exiting with an error:
enrollmentTimeout=120

# This postinstall script for Composer creates the following:
# A LaunchDaemon that starts a separate script to run a Jamf Pro policy command
# A LaunchAgent that runs BigHonkingText soon as the first user logs in
# A script to wait for Jamf Pro enrollment to complete 
# - then triggers a Jamf Pro policy that triggers DEPNotify
# A script that is designed to be called by a Jamf Pro policy 
# - to unload the LaunchDaemon then remove the LaunchDaemon and script
#
# Q: Why not just call the `jamf policy -event` command 
#    from the PreStage Enrollment package postinstall script?
# A: Because the PreStage Enrollment package is installed
#    before the jamf binary is installed.
#
# Q: Why not just have the postinstall script wait until jamf enrollment is complete?
# A: Because the postinstall script won't exit while it waits, which prevents enrollment
#
# Q: Why not just include the Setup-Your-Mac-via-Dialog script in the PreStage Enrollment package?
# A: Because every time you update it, for instance POLICY_ARRAY, 
#    you'd need to re-build and re-upload the package
#
# Q: Why not distribute the extra scripts and LaunchDaemons somewhere else,
#    instead of embedding them in this funky postinstall script?
# A: This way you only have to download and maintain one extra thing.
# 
#
# One approach is to use the following locations and files:
# LaunchDaemon: 
#	/Library/LaunchDaemons/com.lululemon.swiftDialog-prestarter.plist
#
# Temporary folder for the installer and scripts:
#	/usr/local/swiftDialogEnrollment/
#	
# Scripts:
#	/usr/local/swiftDialogEnrollment/com.lululemon.swiftDialog-prestarter-installer.zsh
#	/usr/local/swiftDialogEnrollment/com.lululemon.swiftDialog-prestarter-uninstaller.zsh
#
# The HEREDOC portions of this script that creates additional scripts
# uses the backslash character (\) to prevent commands from being run and
# to prevent variables from being interpreted.
# NOTE: Make sure to leave a full return at the end of HEREDOC 
# content before the last line that defines the end of the HEREDOC content.

#
# This script must be run as root or via Jamf Pro.
# The resulting Script and LaunchDaemon will be run as root.
#
# Update this any of these are changed; 
# The earlier package installer name was swiftDialogInstallerName=DEPNotify-1.1.4.pkg
swiftDialogInstallerName=dialog-2.0.1-3814.pkg
swiftDialogLog="/var/tmp/swiftDialog.log"
swiftDialogAppPath="/usr/local/bin/dialog"

# 
# You can change this if you have a better location to use.
# I haven't tested this with any path that has a space in the name.
tempUtilitiesPath=/usr/local/swiftDialogEnrollment
#
# You can change any of these:
installerBaseString=${organizationIdentifier}.swiftDialog-prestarter
installerScriptName=${installerBaseString}-installer.zsh
installerScriptPath=${tempUtilitiesPath}/${installerScriptName}
uninstallerScriptName=${installerBaseString}-uninstaller.zsh
uninstallerScriptPath=${tempUtilitiesPath}/${uninstallerScriptName}
swiftDialogStarter_Trigger=start-swiftDialog

# It's probably best to not update any of the rest of the script without extensive testing.
#
launchDaemonName=${installerBaseString}.plist
launchDaemonPath="/Library/LaunchDaemons"/${launchDaemonName}
#

# Install the package
/usr/sbin/installer -pkg ${tempUtilitiesPath}/${swiftDialogInstallerName} -target /

# The following creates a script that triggers the Setup-Your-Mac-via-Dialog script to start. 
# Leave a full return at the end of the content before the last "ENDOFINSTALLERSCRIPT" line.
echo "Creating ${installerScriptPath}."
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
		/usr/local/jamf/bin/jamf policy -event ${swiftDialogStarter_Trigger}
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
		/usr/local/jamf/bin/jamf policy -event ${swiftDialogStarter_Trigger}
		exit 0
	fi
fi

# At this point, a user is logged in, but enrollment isn't complete.
# Display a message that they need to wait, but don't display it forever.
# Set up a temporary message for DEPNotify to use
#
echo "Command: MainTitle: Please Wait" >> ${swiftDialogLog}
echo "Command: MainText: ${waitMessage}" >> ${swiftDialogLog}
echo "Status: Waiting to complete enrollment" >> ${swiftDialogLog}

# Assume that because we waited for /var/db/.AppleDiagnosticsSetupDone to exist,
# we are logged in as a real user instead of _mbsetutp user.
#
currentUser=\$( /usr/bin/stat -f %Su /dev/console )
# sudo -u \${currentUser} open -a ${swiftDialogAppPath} ${depNotifyAppFullScreen}

timeoutCounter=0
until [[ -f /var/log/jamf.log ]]
do
	if [[ \$timeoutCounter -ge $enrollmentTimeout ]];
	then
		echo "Gave up waiting for the jamf log to appear."
		killall DEPNotify
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
		killall DEPNotify
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
# 3. DEPNotify is running with a generic wait message
# 

# Stop DEPNotify so the real DEPNotify can start
# /usr/bin/killall DEPNotify

# Remove the DEPNotify log otherwise DEPNotify will fail to open
/bin/rm ${swiftDialogLog}

# Run the policy to call the DEPNotify starter script.
/usr/local/jamf/bin/jamf policy -event ${swiftDialogStarter_Trigger}

ENDOFINSTALLERSCRIPT
) > "${installerScriptPath}"

echo "Setting permissions for ${installerScriptPath}."
chmod 755 "${installerScriptPath}"
chown root:wheel "${installerScriptPath}"

#-----------

# The following creates the LaunchDaemon file 
# that starts the script 
# that waits for Jamf Pro enrollment
# then runs the jamf policy -event command to run your DEPNotify.sh script.
# Leave a full return at the end of the content before the last "ENDOFLAUNCHDAEMON" line.
echo "Creating ${launchDaemonPath}."
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
	<string>/var/tmp/${installerScriptName}.err</string>
	<key>StandardOutPath</key>
	<string>/var/tmp/${installerScriptName}.out</string>
</dict>
</plist>

ENDOFLAUNCHDAEMON
)  > "${launchDaemonPath}"

echo "Setting permissions for ${launchDaemonPath}."
chmod 644 "${launchDaemonPath}"
chown root:wheel "${launchDaemonPath}"

echo "Loading ${launchDaemonName}."
launchctl load "${launchDaemonPath}"

#-----------


# The following creates the script to uninstall the LaunchDaemon and installer script.
# You can create a Jamf Pro policy with the following characteristics:
# General settings:
# --Name: Cleanup DEPNotify Installers
# --Trigger: Custom Trigger: cleanup-depnotify-preinstaller
# --Scope: All Computers
# --Frequency: Once per Computer
# Files and Processes settings:
# --Execute Command: Whatever your $uninstallerScriptPath is set to.
#
# In your DEPNotify.sh script, include the policy near the end of your POLICY_ARRAY.
#
# Leave a full return at the end of the content before the last "ENDOFUNINSTALLERSCRIPT" line.
echo "Creating ${uninstallerScriptPath}."
(
cat <<ENDOFUNINSTALLERSCRIPT
#!/bin/zsh
# This is meant to be called by a Jamf Pro policy via trigger
# Near the end of your POLICY_ARRAY in your DEPNotify.sh script

rm ${tempUtilitiesPath}/${swiftDialogInstallerName}
rm ${installerScriptPath}

# Note that if you unload the LaunchDaemon this will immediately kill the depNotify.sh script
# Just remove the underlying plist file, and the LaunchDaemon will not run after next reboot/login.

rm ${launchDaemonPath}
rm ${uninstallerScriptPath}
rmdir ${tempUtilitiesPath}
rm /var/tmp/${installerScriptName}.err
rm /var/tmp/${installerScriptName}.out

ENDOFUNINSTALLERSCRIPT
) > "${uninstallerScriptPath}"

echo "Setting permissions for ${uninstallerScriptPath}."
chmod 644 "${uninstallerScriptPath}"
chown root:wheel "${uninstallerScriptPath}"

exit 0		## Success
exit 1		## Failure
