#!/bin/bash
set -e

RESUME_CONTAINER=false
OVERRIDE_CONTAINER=false
SKIP_PCIE_INSTALL=false

readonly CONTAINER_NAME="hailo_sw_suite_container"
readonly XAUTH_FILE=$(xauth info | head -n1 | tr -s ' ' | cut -d' ' -f3)
readonly DOCKER_TAR_FILE="hailo_sw_suite_2022_01_ubuntu_20.tar"
readonly DOCKER_IMAGE_NAME="hailo_sw_suite_2022_01_ubuntu_20:v1.1"
readonly NVIDIA_GPU_EXIST=$(lspci | grep "VGA compatible controller: NVIDIA")
readonly NVIDIA_DOCKER_EXIST=$(apt list | grep nvidia-docker)

readonly WHITE="\e[0m"
readonly CYAN="\e[1;36m"
readonly RED="\e[1;31m"
readonly YELLOW="\e[0;33m"

function print_usage() {
    echo "Running Hailo Software Suite Docker image:"
    echo "The default mode will create a new container. If one already exists, use --resume / --override"
    echo ""
    echo "  -h, --help           Show help"
    echo "  --resume             Resume the old container"
    echo "  --override           Delete the existing container and start a new one"
    echo "  --skip-pcie-install  Skip the auto Hailo-8 pcie installation, open new container or override"
    exit 1
}

function parse_args() {
    while test $# -gt 0; do
        if [[ "$1" == "-h" || "$1" == "--help" ]]; then
            print_usage
        elif [ "$1" == "--resume" ]; then
            RESUME_CONTAINER=true
        elif [ "$1" == "--override" ]; then
            OVERRIDE_CONTAINER=true
        elif [ "$1" == "--skip-pcie-install" ]; then
            SKIP_PCIE_INSTALL=true
        else
            echo "Unknown option: $1" && exit 1
        fi
	shift
    done
}

function prepare_docker_args() {
    DOCKER_ARGS="--privileged \
                 --net=host \
                 -e DISPLAY=$DISPLAY \
                 -e XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
                 --device=/dev/dri:/dev/dri \
                 --ipc=host \
                 --group-add 44 \
                 -v $(pwd)/workspace/:/home/hailo/workspace/
                 -v /dev:/dev \
                 -v /lib/firmware:/lib/firmware \
                 -v /lib/modules:/lib/modules \
                 -v /lib/udev/rules.d:/lib/udev/rules.d \
                 -v /usr/src:/usr/src \
                 -v ${XAUTH_FILE}:/home/hailo/.Xauthority \
                 -v /tmp/.X11-unix/:/tmp/.X11-unix/ \
                 --name $CONTAINER_NAME \
                 -v /var/run/docker.sock:/var/run/docker.sock \
                 -v /etc/machine-id:/etc/machine-id:ro \
                 -v /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket
                "
    if [[ -d "/var/lib/dkms" ]]; then
         DOCKER_ARGS+="-v /var/lib/dkms:/var/lib/dkms "
    fi
    if [[ "$SKIP_PCIE_INSTALL" = true ]]; then
        DOCKER_ARGS+="--entrypoint /bin/bash "
    fi
    if [[ $NVIDIA_GPU_EXIST ]] && [[ $NVIDIA_DOCKER_EXIST ]]; then
        DOCKER_ARGS+="--gpus all "
    fi
}

function load_hailo_sw_suite_image() {
    SCRIPT_DIR=$(realpath $(dirname ${BASH_SOURCE[0]}))
    DOCKER_FILE_PATH="${SCRIPT_DIR}/${DOCKER_TAR_FILE}"
    if [[ ! -f "${DOCKER_FILE_PATH}" ]]; then
        echo -e "${RED}Missing file: $DOCKER_FILE_PATH${WHITE} " && exit 1
    fi
    echo -e "${CYAN}Loading Docker image: $DOCKER_FILE_PATH${WHITE}"
    docker load -i $DOCKER_FILE_PATH
}

function run_hailo_sw_suite_image() {
    prepare_docker_args
    RUN_CMD="docker run ${DOCKER_ARGS} -ti $1"
    echo -e "${CYAN}Running Hailo SW suite Docker image with the folowing Docker command:${WHITE}" && echo $RUN_CMD
    $RUN_CMD
}

function check_docker_install_and_user_permmision() {
    if [[ ! $(which docker) ]]; then
        echo -e "${RED}Docker is not installed${WHITE}" && exit 1 
    fi
    docker images &> /dev/null
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}The current user:${USER} is not in the 'Docker' group${WHITE}" && exit 1
    fi
}

function run_new_container() {
    check_docker_install_and_user_permmision
    if [[ $NUM_OF_CONTAINERS_EXSISTS -ge 1 ]]; then
        echo -e "${RED}Can't start a new container, already found one. Consider using --resume or --override${WHITE}"
        echo -e "${RED}In case of replacing the Hailo SW Suite image, delete the existing containers and images${WHITE}"
        echo -e "${RED}Caution, all data from the exist container will be erased. To prevent data loss, save it to your own Docker volume${WHITE}" && exit 1
    elif [ "$(docker images -q $DOCKER_IMAGE_NAME 2> /dev/null)" == "" ]; then
        load_hailo_sw_suite_image
    fi
    echo -e "${CYAN}Starting new container${WHITE}"
    run_hailo_sw_suite_image $DOCKER_IMAGE_NAME
}

function overide_container() {
    if [[ "$NUM_OF_CONTAINERS_EXSISTS" -ge "1" ]]  ; then
        echo -e "${CYAN}Overriding old container${WHITE}"
        docker stop "$CONTAINER_NAME" > /dev/null
        docker rm "$CONTAINER_NAME" > /dev/null
	NUM_OF_CONTAINERS_EXSISTS=$(docker ps -a -q -f "name=$CONTAINER_NAME" | wc -l)
    fi
    run_new_container
}

function resume_container() {
    if [[ "$NUM_OF_CONTAINERS_EXSISTS" -lt "1" ]]; then
        echo -e "${RED}Found no container. please run for the first time without --resume${WHITE} $1"
        exit 1
    fi

    echo -e "${CYAN}Resuming an old container${WHITE} $1"
    # Start and then exec in order to pass the DISPLAY env, because this vairble
    # might change from run to run (after reboot for example)
    docker start "$CONTAINER_NAME"
    docker exec -it -e DISPLAY=$DISPLAY "$CONTAINER_NAME" /bin/bash
}

function main() {
    parse_args "$@"
    # Critical for display
    xhost + &> /dev/null || true
    NUM_OF_CONTAINERS_EXSISTS=$(docker ps -a -q -f "name=$CONTAINER_NAME" | wc -l)
    if [ "$RESUME_CONTAINER" = true ]; then
        resume_container
    elif [ "$OVERRIDE_CONTAINER" = true ] || [ "$SKIP_PCIE_INSTALL" = true ]; then
        overide_container
    else
        run_new_container
    fi
}

main "$@"
