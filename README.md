# SetupYourMac

1. Copy SetupYourMac.sh to Jamf Pro scripts
2. Create a policy in Jamf Pro using the Scripts payload to run SetupYourMac.sh, this policy needs a custom trigger 'start-swiftDialog'
3. Create an enrollment package that installs swiftDialog in the PreStage, and runs the EnrollmentPostInstall.zsh script.
