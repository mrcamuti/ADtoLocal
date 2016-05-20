#!/bin/bash
VERSION=1.5
/usr/bin/logger -t "ADtoLocal" "Running $VERSION of migration from mobile to local."
# Move a Mobile (AD) account to a local account
# Heavily derived from https://macmule.com/2013/02/18/correct-ad-users-home-mobile-home-folder-permissions/
# http://stackoverflow.com/questions/4213453/bash-regex-for-strong-password
# https://www.gov.uk/government/uploads/system/uploads/attachment_data/file/268658/osx-provisioning-script.txt

# Resources referenced by this script
BIGTEXT=$(dirname "$0")/BigHonkingText
FVSTATUS=$(dirname "$0")/filevault_2_status_check.sh
OS_MINOR=$(sw_vers -productVersion | awk -F. '{print $2}')

################################################
#  User-facing variables - EDIT THIS SECTION   #
################################################
ADADMINUSER='ADAdminAccountThatCanRemoveComps' #
ADADMINPASSWORD='PA$$w0rd_for_ADADMINUSER'     #
STAFFID='20'                                   #
FV2ADMIN='localuseradmin'                      #
UNLOCKFV2PASSWORD='PASSW0rd_for_FV2ADMIN_acct' #
SAMANAGE_ACCOUNT='Account_Code'                #
ARDADMIN='shortname_of_ARD_account'            #
################################################

cat << EOF1
#################################################################################
#                                                                               #
#   This script assumes that you                                                #
#         1) have an active internet connection                                 #
#         2) have a Mobile Active Directory user account on this system         #
#                                                                               #
#     If those assumptions are false, contact helpdesk for assistance.          #
#                                                                               #
#     Must be run as from an administrator's account.                           #
#     Must NOT be run from the account you are trying to migrate.               #
#                                                                               #
#################################################################################

If asked for a password immediately following this entry, it's invoking sudo
powers, use the admin account password for the account you're logged into.

EOF1
sudo chmod +x "${BIGTEXT}"
sudo chmod +x "${FVSTATUS}"
cat << EOF2
#########################################################
#                      Sudo done                        #
#########################################################
EOF2

# running this script as root check (which makes it harder to check if we are logged into an account set to migrate)
if [ $(whoami) != "root" ]
  then
	"${BIGTEXT}" "Logged in as a non-root account, proceeding"
  else
	"${BIGTEXT}" "Try re-running this script without sudo powers"
	"${BIGTEXT}" "Exiting"
	exit 1
fi

# are we logged into a migration-target account?
if [ $(id -u) -gt 999 ]
  then
	"${BIGTEXT}" "Logged in as an AD account, which needs to migrate"
	"${BIGTEXT}" "Log into another admin (non-AD) account, and re-run"
	exit 2
fi

# Confirm that they want to initiate this migration process
cat << EOF2
This script will delete your Active Directory user and migrate that data to a local account.

***Seriously, read this***
EOF2

sleep 5
CONFIRM=0
# Set a password that will be applied to all local acccounts
while [ ${CONFIRM} == 0 ]; do
	echo "You will also be setting local account password that will be separate from your network password."
	echo ""
	echo "Your local password must contain:"
	echo "•	Uppercase characters (A-Z)"
	echo "•	Lowercase characters (a-z)"
	echo "•	Numbers (0-9)"
	echo ""
	# if the result string is empty, one of the conditions has failed
	if [ -z ${COMPLEXITYCHECK} ]
	  then
		echo ""
		echo "*THIS PASSWORD WILL BE APPLIED TO ALL LOCAL ACCOUNTS WE ARE MAKING*"
		echo -n "Please enter your new password (input hidden for security):"
		read -s LOCALPASSWORD
		# Check the complexity of a password they set, then store it to assign that password to the new user account
		COMPLEXITYCHECK=$(echo $LOCALPASSWORD | egrep "[ABCDEFGHIJKLMNOPQRSTUVWXYZ]" | egrep "[abcdefghijklmnopqrstuvwxyz"] | egrep "[0-9]" | egrep -v -i "password" )
	  else
		echo ""
	    echo "Password satisfies complexity requirements"
		echo ""
		CONFIRM=$((CONFIRM+1))
	fi
done

echo ""
echo "Running a bunch of permissions changes, this could take a couple minutes."
echo ""

#################
#	Functions	#
#################

# Capture orignal information from the Mobile account being migrated
function GATHERMOBILEINFO {
	# resolve their POSIX ID to their user name
	USRNAME=$(id -p ${i} | head -n1 | awk '{ print $2 }')
	# Capture their Real Name, for use later
	REALNAME=$(echo $(dscl . read /Users/$USRNAME | grep -A 1 RealName | tail -n1))
	# Capture their current shell, for use later
	ORIGSHELL=$(dscl . -read /Users/$USRNAME UserShell | awk '{ print $2 }')
	# Specify current Home directory, in case they renamed or moved it from /Users/$shortname
	HOMEDIR=$(dscl . -read /Users/$USRNAME NFSHomeDirectory | awk '{ print $2 }')
}

# Make new Account, setup necessary variables
function CREATEUSER {
	# make new local administrator account using short name, from above
	sudo dscl . create /Users/${USRNAME}
	# Set shell, for completeness of user account creation, since OS X expects this
	sudo dscl . create /Users/${USRNAME} UserShell ${ORIGSHELL}
	# Set user's Long Name to the same as the Mobile account
	sudo dscl . create /Users/${USRNAME} RealName "${REALNAME}"
	# Check the current UID list and set a unique ID for the new user.
	for n in $(dscl . -list /Users UniqueID | awk '{print $2}' | sort -ug )
	do
		if [ ${n} -lt 999 ]; then
			USERID=$((n+1))
		fi
	done
	sudo dscl . create /Users/${USRNAME} UniqueID ${USERID}
	# Next, we’ll create and set the user’s group ID property:
	sudo dscl . create /Users/${USRNAME} PrimaryGroupID ${STAFFID}
	# Now, we’ll set the user’s home directory by running the following command. Ensure that you replace both instances of the shortname in the command below:
	sudo dscl . create /Users/${USRNAME} NFSHomeDirectory ${HOMEDIR}
	# Now we’ll add some security to the user account and set their password. Here, you’ll replace “PASSWORD” with the actual password that will be used initially for their account. The user can always change the password later:
	sudo dscl . passwd /Users/${USRNAME} ${LOCALPASSWORD}
	# If the user will have administrator privileges, then we’ll run the following account to assign that title to the newly minted user:
	sudo dscl . append /Groups/admin GroupMembership ${USRNAME}
}

# FileVault 2 Status Check - TROUTON SCRIPT INTEGRATION
function FVADDCHECK {
	"${FVSTATUS}" | grep "FileVault 2 Encryption Complete" 2>&1 >/dev/null
	if [ $? == 0 ]
	  then
		# Enable the new local admin account to unlock the FV2 encrypted volume	
		export LOCALPASSWORD
		export USRNAME
		if [ ${OS_MINOR} == 8 ]
			then expect -c "spawn sudo /usr/bin/fdesetup add -usertoadd \"${USRNAME}\"; expect \":\"; send \"${FV2ADMIN}\n\"; expect \":\"; send \"${UNLOCKFV2PASSWORD}\n\" ; expect \":\"; send \"${LOCALPASSWORD}\n\"; expect eof"
		fi
		if [ ${OS_MINOR} -ge 9 ]
			then expect -c "spawn sudo /usr/bin/fdesetup add -usertoadd \"${USRNAME}\"; expect \":\"; send \"${UNLOCKFV2PASSWORD}\n\" ; expect \":\"; send \"${LOCALPASSWORD}\n\"; expect eof"
		fi
		# Check if the new in account was successfully added to the FileVault 2 authorized unlock list
			sudo fdesetup list | grep ${USRNAME} 2>&1 >/dev/null
			if [ $? == 0 ]
			  then
				echo "User appears in the authorized FileVault 2 list."
			  else
				echo "Failed to add user to FileVault 2 list."
				echo ""
				echo "***"
				echo "Contact helpdesk immediately."
				echo "***"
				echo ""
				echo "Do NOT turn off your computer before hearing back from helpdesk, or you will not be able to log back in."
				echo ""
				sleep 5
			fi
		else
			echo "FileVault not turned on, proceeding"
	fi
}

# ensure ARD enrollment is setup, for remote support
function ARDENROLL {
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart -activate -configure -access -on -users ${ARDADMIN} -privs -all -restart -agent -menu
sudo defaults write /Library/Preferences/com.apple.loginwindow HiddenUsersList -array-add ${ARDADMIN}
}

# Install the SAManage agent, so we can keep track of machines
function SAMANAGE {
		# Uninstall current SAManage agent
	sudo /Applications/Samanage\ Agent.app/Contents/Resources/uninstaller.sh
	
	# Change working directory to /tmp
	cd /tmp
	
	# Download SAManage Mac agent software
	curl -O http://cdn.samanage.com/download/Mac+Agent/SAManage-Agent-for-Mac.dmg
	
	# Mount the SAManage-Agent-for-Mac.dmg disk image as /tmp/SAManage-Mac-Agent
	hdiutil attach SAManage-Agent-for-Mac.dmg -nobrowse -noverify -noautoopen
	
	# Replace <ACCT_NAME> with your Samanage account name below
	echo ${SAMANAGE_ACCOUNT} > /tmp/samanage
	
	# Install the SAManage Mac agent
	sudo installer -dumplog -verbose -pkg /Volumes/Samanage-Mac-Agent-*/Samanage-Mac-Agent-*.pkg -target "/"
	
	# Clean-up
	# Unmount the SAManage-Agent-for-Mac.dmg disk image from /Volumes
	hdiutil eject -force /Volumes/Samanage-Mac-Agent-*
	
	# Remove /tmp/samanage
	sudo rm /tmp/samanage
	sudo rm /tmp/samanage_no_soft
	
	# Remove the SAManage-Agent-for-Mac.dmg disk image from /tmp
	sudo rm /tmp/SAManage-Agent-for-Mac.dmg
}

#####################
#	Main Program	#
#####################

# Remove from AD and remove User account
sudo dsconfigad -force -remove -u ${ADADMINUSER} -p ${ADADMINPASSWORD}

# For each AD account found, make them a new user, give them the correct permissions to the original files
for i in $(dscl localhost list /Local/Default/Users UniqueID | awk '{ print $2 }' | sort -g | tr ' ' '\n')
do	
	if [ ${i} -lt 999 ]
	  then
		continue
	fi

	GATHERMOBILEINFO

	# test if target account is mobile or not
	if [ ${i} -ge 999 ]
	  then 
		"${BIGTEXT}" "$USRNAME is an AD account"
	  else
		"${BIGTEXT}" "No AD accounts found, exiting"
		exit 3
	fi

	# Delete mobile (AD) User account
	sudo dscl . delete /Users/${USRNAME}
	
	### Clean up permissions on old Home folder
	# removing ACLs
	sudo chmod -R -N /Users/${USRNAME}
	# clear locked files and folders
	sudo chflags -R nouchg /Users/${USRNAME}

	CREATEUSER
	FVADDCHECK

	# update ownership to local account with correct group ownership
	sudo chown -R ${USERID}:${STAFFID} /Users/${USRNAME}
done

unset LOCALPASSWORD

ARDENROLL

SAMANAGE
