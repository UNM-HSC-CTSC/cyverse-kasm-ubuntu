#!/bin/bash
### every exit != 0 fails the script
set -e

if [ -f /data-store/iplant/home/$IPLANT_USER/.gitconfig ]; then
  cp /data-store/iplant/home/$IPLANT_USER/.gitconfig ~/
fi

if [ -d /data-store/iplant/home/$IPLANT_USER/.ssh ]; then
  cp -r /data-store/iplant/home/$IPLANT_USER/.ssh ~/
fi

no_proxy="localhost,127.0.0.1"

if [ -f /usr/bin/kasm-profile-sync ]; then
	kasm_profile_sync_found=1
fi

# Set lang values
if [ "${LC_ALL}" != "en_US.UTF-8" ]; then
  export LANG=${LC_ALL}
  export LANGUAGE=${LC_ALL}
fi

# dict to store processes
declare -A KASM_PROCS

# switch passwords to local variables
tmpval=$VNC_VIEW_ONLY_PW
unset VNC_VIEW_ONLY_PW
VNC_VIEW_ONLY_PW=$tmpval
tmpval=$VNC_PW
unset VNC_PW
VNC_PW=$tmpval

BUILD_ARCH=$(uname -p)
if [ -z ${KASM_PROFILE_CHUNK_SIZE} ]; then
  KASM_PROFILE_CHUNK_SIZE=100000
fi
# Resolve the DRM node this container was actually allocated. On a multi-GPU
# host the NVIDIA device plugin injects only the nodes belonging to the GPU it
# handed us (e.g. card4/renderD131), but Xvnc hardcodes card0/renderD128 and
# treats a missing node as fatal ("Failed to create gbm"). dri-node-setup.sh
# symlinks the defaults onto the allocated node and echoes that node back here.
# Run out-of-process and swallow failures: a GPU quirk must not abort startup.
KASM_DRI_RENDER_NODE=""
if [ -x /dockerstartup/dri-node-setup.sh ]; then
  KASM_DRI_RENDER_NODE=$(/dockerstartup/dri-node-setup.sh) || \
    echo "dri-node-setup.sh failed; falling back to defaults" >&2
fi

if [ -z ${DRINODE+x} ]; then
  DRINODE="${KASM_DRI_RENDER_NODE:-/dev/dri/renderD128}"
fi
KASMNVC_HW3D=''
if [ ! -z ${HW3D+x} ]; then
  KASMVNC_HW3D="-hw3d"
fi
STARTUP_COMPLETE=0

######## FUNCTION DECLARATIONS ##########

## print out help
function help (){
	echo "
		USAGE:

		OPTIONS:
		-w, --wait      (default) keeps the UI and the vncserver up until SIGINT or SIGTERM will received
		-s, --skip      skip the vnc startup and just execute the assigned command.
		                example: docker run kasmweb/core --skip bash
		-d, --debug     enables more detailed startup output
		                e.g. 'docker run kasmweb/core --debug bash'
		-h, --help      print out this help

		Fore more information see: https://github.com/ConSol/docker-headless-vnc-container
		"
}

trap cleanup SIGINT SIGTERM SIGQUIT SIGHUP ERR

function pull_profile (){
	if [ ! -z "$KASM_PROFILE_LDR" ]; then
		if [ -z "$kasm_profile_sync_found" ]; then
			echo >&2 "Profile sync not available"
			sleep 3
			http_proxy="" https_proxy="" curl -k "https://${KASM_API_HOST}:${KASM_API_PORT}/api/set_kasm_session_status?token=${KASM_API_JWT}" -H 'Content-Type: application/json' -d '{"status": "running"}'
			return
		fi

		echo "Downloading and unpacking user profile from object storage."
		set +e
		http_proxy="" https_proxy="" /usr/bin/kasm-profile-sync --download /home/kasm-user --insecure --remote ${KASM_API_HOST} --port ${KASM_API_PORT} -c ${KASM_PROFILE_CHUNK_SIZE} --token ${KASM_API_JWT}
		PROCESS_SYNC_EXIT_CODE=$?
		set -e
		if (( PROCESS_SYNC_EXIT_CODE > 1 )); then
			echo "Profile-sync failed with a non-recoverable error. See server side logs for more details."
			exit 1
		fi
		echo "Profile load complete."
		# Update the status of the container to running
		sleep 3
		http_proxy="" https_proxy="" curl -k "https://${KASM_API_HOST}:${KASM_API_PORT}/api/set_kasm_session_status?token=${KASM_API_JWT}" -H 'Content-Type: application/json' -d '{"status": "running"}'

	fi
}

function profile_size_check(){
	if [ ! -z "$KASM_PROFILE_SIZE_LIMIT" ]
	then
		SIZE_CHECK_FAILED=false
		while true
		do
			sleep 60
			CURRENT_SIZE=$(du -s $HOME | grep -Po '^\d+')
			SIZE_LIMIT_MB=$(echo "$KASM_PROFILE_SIZE_LIMIT / 1000" | bc)
			if [[ $CURRENT_SIZE -gt KASM_PROFILE_SIZE_LIMIT ]]
			then
				notify-send "Profile Size Exceeds Limit" "Your home profile has exceeded the size limit of ${SIZE_LIMIT_MB}MB. Changes on your desktop will not be saved between sessions until you reduce the size of your profile." -i /usr/share/icons/ubuntu-mono-dark/apps/22/dropboxstatus-x.svg -t 57000
				SIZE_CHECK_FAILED=true
			else
				if [ "$SIZE_CHECK_FAILED" = true ] ; then
					SIZE_CHECK_FAILED=false
					notify-send "Profile Size" "Your home profile size is now under the limit and will be saved when your session is terminated." -i /usr/share/icons/ubuntu-mono-dark/apps/22/dropboxstatus-logo.svg -t 57000
				fi
			fi
		done
	fi
}

## correct forwarding of shutdown signal
function cleanup () {
    kill -s SIGTERM $!
    exit 0
}

function start_kasmvnc (){
	if [[ $DEBUG == true ]]; then
	  echo -e "\n------------------ Start KasmVNC Server ------------------------"
	fi

	DISPLAY_NUM=$(echo $DISPLAY | grep -Po ':\d+')

	if [[ $STARTUP_COMPLETE == 0 ]]; then
	    vncserver -kill $DISPLAY &> $STARTUPDIR/vnc_startup.log \
	    || rm -rfv /tmp/.X*-lock /tmp/.X11-unix &> $STARTUPDIR/vnc_startup.log \
	    || echo "no locks present"
	fi

	rm -rf $HOME/.vnc/*.pid
	echo "exit 0" > $HOME/.vnc/xstartup
	chmod +x $HOME/.vnc/xstartup

	VNCOPTIONS="$VNCOPTIONS -select-de manual"

	if [[ ${KASM_SVC_PRINTER:-1} == 1 ]]; then
		VNCOPTIONS="$VNCOPTIONS -UnixRelay printer:/tmp/printer"
	fi

	if [[ "${BUILD_ARCH}" =~ ^aarch64$ ]] && [[ -f /lib/aarch64-linux-gnu/libgcc_s.so.1 ]] ; then
		LD_PRELOAD=/lib/aarch64-linux-gnu/libgcc_s.so.1 vncserver $DISPLAY -disableBasicAuth $KASMVNC_HW3D -drinode $DRINODE -depth $VNC_COL_DEPTH -geometry $VNC_RESOLUTION -websocketPort $NO_VNC_PORT -httpd ${KASM_VNC_PATH}/www -FrameRate=$MAX_FRAME_RATE -interface 0.0.0.0 -BlacklistThreshold=0 -FreeKeyMappings $VNCOPTIONS $KASM_SVC_SEND_CUT_TEXT $KASM_SVC_ACCEPT_CUT_TEXT
	else
		vncserver $DISPLAY -disableBasicAuth $KASMVNC_HW3D -drinode $DRINODE -depth $VNC_COL_DEPTH -geometry $VNC_RESOLUTION -websocketPort $NO_VNC_PORT -httpd ${KASM_VNC_PATH}/www -FrameRate=$MAX_FRAME_RATE -interface 0.0.0.0 -BlacklistThreshold=0 -FreeKeyMappings $VNCOPTIONS $KASM_SVC_SEND_CUT_TEXT $KASM_SVC_ACCEPT_CUT_TEXT
	fi

	KASM_PROCS['kasmvnc']=$(cat $HOME/.vnc/*${DISPLAY_NUM}.pid)

	#Disable X11 Screensaver
	if [ "${DISTRO}" != "alpine" ]; then
		echo "Disabling X Screensaver Functionality"
		xset -dpms
		xset s off
		xset q
	else
		echo "Disabling of X Screensaver Functionality for $DISTRO is not required."
	fi

	if [[ $DEBUG == true ]]; then
	  echo -e "\n------------------ Started Websockify  ----------------------------"
	  echo "Websockify PID: ${KASM_PROCS['kasmvnc']}";
	fi
}

function start_window_manager (){
	echo -e "\n------------------ Xfce4 window manager startup------------------"

	if [ "${START_XFCE4}" == "1" ] ; then
		if [ -f /opt/VirtualGL/bin/vglrun ] && [ ! -z "${KASM_EGL_CARD}" ] && [ ! -z "${KASM_RENDERD}" ] && [ -O "${KASM_RENDERD}" ] && [ -O "${KASM_EGL_CARD}" ] ; then
		echo "Starting XFCE with VirtualGL using EGL device ${KASM_EGL_CARD}"
			DISPLAY=:1 /opt/VirtualGL/bin/vglrun -d "${KASM_EGL_CARD}" /usr/bin/startxfce4 --replace &
		else
			echo "Starting XFCE"
			if [ -f '/usr/bin/zypper' ]; then
				DISPLAY=:1 /usr/bin/dbus-launch /usr/bin/startxfce4 --replace &
			else
				/usr/bin/startxfce4 --replace &
			fi
		fi
		KASM_PROCS['window_manager']=$!
	else
		echo "Skipping XFCE Startup"
	fi
}

function start_audio_out_websocket (){
	if [[ ${KASM_SVC_AUDIO:-1} == 1 ]]; then
		echo 'Starting audio websocket server'
		$STARTUPDIR/jsmpeg/kasm_audio_out-linux kasmaudio 8081 4901 ${HOME}/.vnc/self.pem ${HOME}/.vnc/self.pem "kasm_user:$VNC_PW"  &

		KASM_PROCS['kasm_audio_out_websocket']=$!

		if [[ $DEBUG == true ]]; then
		  echo -e "\n------------------ Started Audio Out Websocket  ----------------------------"
		  echo "Kasm Audio Out Websocket PID: ${KASM_PROCS['kasm_audio_out_websocket']}";
		fi
	fi
}

function start_audio_out (){
	if [[ ${KASM_SVC_AUDIO:-1} == 1 ]]; then
		echo 'Starting audio server'

        if [ "${START_PULSEAUDIO:-0}" == "1" ] ;
        then
            echo "Starting Pulse"
            HOME=/var/run/pulse pulseaudio --start
        fi

		if [[ $DEBUG == true ]]; then
			echo 'Starting audio service in debug mode'
			HOME=/var/run/pulse no_proxy=127.0.0.1 ffmpeg -f pulse -fragment_size ${PULSEAUDIO_FRAGMENT_SIZE:-2000} -ar 44100 -i default -f mpegts -correct_ts_overflow 0 -codec:a mp2 -b:a 128k -ac 1 -muxdelay 0.001 http://127.0.0.1:8081/kasmaudio &
			KASM_PROCS['kasm_audio_out']=$!
		else
			echo 'Starting audio service'
			HOME=/var/run/pulse no_proxy=127.0.0.1 ffmpeg -v verbose -f pulse -fragment_size ${PULSEAUDIO_FRAGMENT_SIZE:-2000} -ar 44100 -i default -f mpegts -correct_ts_overflow 0 -codec:a mp2 -b:a 128k -ac 1 -muxdelay 0.001 http://127.0.0.1:8081/kasmaudio > /dev/null 2>&1 &
			KASM_PROCS['kasm_audio_out']=$!
			echo -e "\n------------------ Started Audio Out  ----------------------------"
			echo "Kasm Audio Out PID: ${KASM_PROCS['kasm_audio_out']}";
		fi
	fi
}

function start_audio_in (){
	if [[ ${KASM_SVC_AUDIO_INPUT:-1} == 1 ]]; then
		echo 'Starting audio input server'
		$STARTUPDIR/audio_input/kasm_audio_input_server --ssl --auth-token "kasm_user:$VNC_PW" --cert ${HOME}/.vnc/self.pem --certkey ${HOME}/.vnc/self.pem &

		KASM_PROCS['kasm_audio_in']=$!

		if [[ $DEBUG == true ]]; then
			echo -e "\n------------------ Started Audio Out Websocket  ----------------------------"
			echo "Kasm Audio In PID: ${KASM_PROCS['kasm_audio_in']}";
		fi
	fi
}

function start_upload (){
	if [[ ${KASM_SVC_UPLOADS:-1} == 1 ]]; then
		echo 'Starting upload server'
		$STARTUPDIR/upload_server/kasm_upload_server --ssl --auth-token "kasm_user:$VNC_PW" &

		KASM_PROCS['upload_server']=$!

		if [[ $DEBUG == true ]]; then
			echo -e "\n------------------ Started Upload Server  ----------------------------"
			echo "Upload Server PID: ${KASM_PROCS['upload_server']}";
		fi
	fi
}

function start_gamepad (){
	if [[ ${KASM_SVC_GAMEPAD:-1} == 1 ]]; then
		echo 'Starting gamepad server'
		$STARTUPDIR/gamepad/kasm_gamepad_server --ssl --auth-token "kasm_user:$VNC_PW" --cert ${HOME}/.vnc/self.pem --certkey ${HOME}/.vnc/self.pem &

		KASM_PROCS['kasm_gamepad']=$!

		if [[ $DEBUG == true ]]; then
			echo -e "\n------------------ Started Gamepad Websocket  ----------------------------"
			echo "Kasm Gamepad PID: ${KASM_PROCS['kasm_gamepad']}";
		fi
	fi
}

function start_webcam (){
	if [[ ${KASM_SVC_WEBCAM:-1} == 1 ]] && [[ -e /dev/video0 ]]; then
		echo 'Starting webcam server'
                if [[ $DEBUG == true ]]; then
			$STARTUPDIR/webcam/kasm_webcam_server --debug --port 4905 --ssl --cert ${HOME}/.vnc/self.pem --certkey ${HOME}/.vnc/self.pem &
		else
			$STARTUPDIR/webcam/kasm_webcam_server --port 4905 --ssl --cert ${HOME}/.vnc/self.pem --certkey ${HOME}/.vnc/self.pem &
		fi

		KASM_PROCS['kasm_webcam']=$!

		if [[ $DEBUG == true ]]; then
			echo -e "\n------------------ Started Webcam Websocket  ----------------------------"
			echo "Kasm Webcam PID: ${KASM_PROCS['kasm_webcam']}";
		fi
	fi
}

function start_printer (){
		if [[ ${KASM_SVC_PRINTER:-1} == 1 ]]; then
			echo 'Starting printer service'
            if [[ $DEBUG == true ]]; then
			    $STARTUPDIR/printer/kasm_printer_service --debug --directory $HOME/PDF --relay /tmp/printer &
		    else
			    $STARTUPDIR/printer/kasm_printer_service --directory $HOME/PDF --relay /tmp/printer &
		    fi

		KASM_PROCS['kasm_printer']=$!

		if [[ $DEBUG == true ]]; then
			echo -e "\n------------------ Started Printer Service  ----------------------------"
			echo "Kasm Printer PID: ${KASM_PROCS['kasm_printer']}";
		fi
	fi
}

function custom_startup (){
	custom_startup_script=/dockerstartup/custom_startup.sh
	if [ -f "$custom_startup_script" ]; then
		if [ ! -x "$custom_startup_script" ]; then
			echo "${custom_startup_script}: not executable, exiting"
			exit 1
		fi

		"$custom_startup_script" &
		KASM_PROCS['custom_startup']=$!
	fi
}

# Optional user init hook, run once and to completion before the desktop
# starts. Unlike custom_startup() above (a script baked into the image), this
# one is supplied by the user at launch time. The DE's "User init script" app
# parameter reaches us as `--init-script <basename>`, so that parameter's
# "Argument option" field must be set to --init-script in the DE; leave it
# empty and only the bare value is passed, which this also accepts since
# vnc_startup.sh declares no CMD, so argv is empty unless the DE supplied a
# parameter. VICE_INIT_SCRIPT does the same for testing outside the DE.
# A hook is capped at a flat two minutes, deliberately not configurable: the
# cap protects startup, and a knob to raise it would just be a knob to defeat it.
function run_user_init_hook (){
    local init_log="$HOME/.vice-init.log"
    local init_script="${VICE_INIT_SCRIPT:-}"
    local hook status

    echo "vnc_startup.sh args: $*" >> "$init_log"

    # Shift one at a time. `shift 2` is a trap here: a parameter left blank in
    # the DE arrives as a bare trailing --init-script, and shifting past the
    # end is a no-op that spins forever.
    while [ $# -gt 0 ]; do
        case "$1" in
            --init-script) init_script="${2:-}" ;;
            -h|--help|-w|--wait|-s|--skip|-d|--debug) ;;
            *) [ -n "$init_script" ] || init_script="$1" ;;
        esac
        shift
    done

    [ -n "$init_script" ] || return 0

    # Whichever file the user selects, the CSI driver stages it at this fixed
    # path for the launch -- regardless of which directory in the data store
    # it was picked from -- so it's the sole source of truth; nothing here
    # searches elsewhere for a name match. `basename` also strips any
    # directory components from $init_script, so the constructed path can
    # never land outside this one staged directory.
    hook="$HOME/data-store/data/input/$(basename "$init_script")"
    if [ ! -f "$hook" ] || [ ! -r "$hook" ]; then
        echo "init hook: no script staged at $hook" >> "$init_log"
        return 0
    fi

    echo "Running user init hook: $hook (log $init_log)"
    # `bash "$hook"` rather than `"$hook"`: the executable bit does not
    # survive the data store. A child process rather than `source`: a sourced
    # hook could clobber this script.
    timeout --kill-after=10 120 bash "$hook" >> "$init_log" 2>&1
    status=$?
    case "$status" in
        0) ;;
        124|137) echo "init hook: timed out after 120s and was killed, continuing with defaults" | tee -a "$init_log" ;;
        *) echo "init hook: exited $status, continuing with defaults" | tee -a "$init_log" ;;
    esac
}

############ END FUNCTION DECLARATIONS ###########

if [[ $1 =~ -h|--help ]]; then
    help
    exit 0
fi

# Syncronize user-space loaded persistent profiles
pull_profile

# Land the whole startup process -- and so the desktop session and every
# terminal launched from it -- in $HOME, regardless of the container's actual
# working directory. That has to stay at data-store: the DE mounts the
# analysis's persistent volume at the container's working directory, so
# pointing it at $HOME would mount a volume over the home directory and hide
# .bashrc and everything else this image installs. The DE/K8s pod spec can
# (and does) override the image's own WORKDIR, so this is the only place that
# reliably lands the session in ~ either way.
cd "$HOME" || true

# should also source $STARTUPDIR/generate_container_user
if [ -f $HOME/.bashrc ]; then
    source $HOME/.bashrc
fi

# Run the optional user init hook now: profile restore and .bashrc are done,
# so the hook has a fully set up environment, and it runs before the desktop
# starts so it can prepare the session (e.g. clone a repo, install a package).
run_user_init_hook "$@"

if [[ ${KASM_DEBUG:-0} == 1 ]]; then
    echo -e "\n\n------------------ DEBUG KASM STARTUP -----------------"
    export DEBUG=true
    set -x
fi

## resolve_vnc_connection
VNC_IP=$(hostname -i)
if [[ $DEBUG == true ]]; then
    echo "IP Address used for external bind: $VNC_IP"
fi

# Create cert for KasmVNC
mkdir -p ${HOME}/.vnc
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout ${HOME}/.vnc/self.pem -out ${HOME}/.vnc/self.pem -subj "/C=US/ST=VA/L=None/O=None/OU=DoFu/CN=kasm/emailAddress=none@none.none"

# first entry is control, second is view (if only one is valid for both)
mkdir -p "$HOME/.vnc"
PASSWD_PATH="$HOME/.kasmpasswd"
if [[ -f $PASSWD_PATH ]]; then
    echo -e "\n---------  purging existing VNC password settings  ---------"
    rm -f $PASSWD_PATH
fi
VNC_PW_HASH=$(/usr/bin/python3 -c "import crypt; print(crypt.crypt('${VNC_PW}', '\$5\$kasm\$'));")
VNC_VIEW_PW_HASH=$(/usr/bin/python3 -c "import crypt; print(crypt.crypt('${VNC_VIEW_ONLY_PW}', '\$5\$kasm\$'));")
echo "kasm_user:${VNC_PW_HASH}:ow" > $PASSWD_PATH
echo "kasm_viewer:${VNC_VIEW_PW_HASH}:" >> $PASSWD_PATH
chmod 600 $PASSWD_PATH


# start processes
start_kasmvnc

# GUI apps on this desktop can only render through Mesa's software rasteriser.
# Xvnc is not an NVIDIA X server, and Mesa has no userspace driver for the
# nvidia-drm kernel driver behind the DRM nodes the device plugin injects. Left
# to probe, every GL client walks the hardware path first and fails --
#
#   pci id for fd 23: 10de:2bb5, driver (null)
#   glx: failed to create dri3 screen
#   failed to load driver: nvidia-drm
#
# -- before falling back to swrast. GTK4 and Electron apps do not all recover
# from that cleanly, which is what broke Chrome, VS Code and gnome-system-monitor
# here; the non-GPU image never hits it because it has no /dev/dri for DRI3 to
# offer. Telling Mesa up front skips the doomed probe entirely.
#
# Exported *after* start_kasmvnc so Xvnc's own GBM initialisation on the
# allocated NVIDIA node is unaffected, and inherited by the window manager and
# everything launched from the desktop. vglrun-wrapper.sh unsets it for apps
# that genuinely want the GPU.
export LIBGL_ALWAYS_SOFTWARE=1

start_window_manager
start_audio_out_websocket
start_audio_out
start_audio_in
start_upload
start_gamepad
profile_size_check &
start_webcam
start_printer

STARTUP_COMPLETE=1


## log connect options
echo -e "\n\n------------------ KasmVNC environment started ------------------"

# tail vncserver logs
tail -f $HOME/.vnc/*$DISPLAY.log &

KASMIP=$(hostname -i)
echo "Kasm User ${KASM_USER}(${KASM_USER_ID}) started container id ${HOSTNAME} with local IP address ${KASMIP}"

# start custom startup script
custom_startup

# Monitor Kasm Services
sleep 3
while :
do
	for process in "${!KASM_PROCS[@]}"; do
		if ! kill -0 "${KASM_PROCS[$process]}" ; then

			# If DLP Policy is set to fail secure, default is to be resilient
			if [[ ${DLP_PROCESS_FAIL_SECURE:-0} == 1 ]]; then
				exit 1
			fi

			case $process in
				kasmvnc)
					if [ "$KASMVNC_AUTO_RECOVER" = true ] ; then
						echo "KasmVNC crashed, restarting"
						start_kasmvnc
					else
						echo "KasmVNC crashed, exiting container"
						exit 1
					fi
					;;
				window_manager)
					echo "Window manager crashed, restarting"
					start_window_manager
					;;
				kasm_audio_out_websocket)
					echo "Restarting Audio Out Websocket Service"
					start_audio_out_websocket
					;;
				kasm_audio_out)
					echo "Restarting Audio Out Service"
					start_audio_out
					;;
				kasm_audio_in)
					echo "Audio In Service Failed"
					# TODO: Needs work in python project to support auto restart
					# start_audio_in
					;;
				upload_server)
					echo "Restarting Upload Service"
					# TODO: This will only work if both processes are killed, requires more work
					start_upload
					;;
                                kasm_gamepad)
					echo "Gamepad Service Failed"
					# TODO: Needs work in python project to support auto restart
					# start_gamepad
					;;
				kasm_webcam)
					echo "Webcam Service Failed"
					# TODO: Needs work in python project to support auto restart
					start_webcam
					;;
				kasm_printer)
					echo "Printer Service Failed"
					# TODO: Needs work in python project to support auto restart
					start_printer
					;;
				custom_script)
					echo "The custom startup script exited."
					# custom startup scripts track the target process on their own, they should not exit
					custom_startup
					;;
				*)
					echo "Unknown Service: $process"
					;;
			esac
		fi
	done
	sleep 3
done


echo "Exiting Kasm container"