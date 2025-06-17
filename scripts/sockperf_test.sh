#!/bin/bash

SERVER_IP="10.10.1.1"
CLIENT_IP="10.10.1.2"
PORT="11111"
CPU_CORE="9"
MSG_SIZE="64"
TEST_TIME="30"
PROTOCOL="tcp"
SERVER_USER="jcarin"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Runs sockperf ping-pong test by automatically starting server via SSH"
    echo ""
    echo "Options:"
    echo "  -p, --port PORT       Port number (default: ${PORT})"
    echo "  -c, --core CORE       CPU core to pin to (default: ${CPU_CORE})"
    echo "  -s, --size SIZE       Message size in bytes (default: ${MSG_SIZE})"
    echo "  -t, --time TIME       Test duration in seconds (default: ${TEST_TIME})"
    echo "  -u, --udp             Use UDP protocol (default: TCP)"
    echo "  --tcp                 Use TCP protocol (default)"
    echo "  -i, --ip IP           Server IP address (default: ${SERVER_IP})"
    echo "  --user USER           SSH username for server (default: ${SERVER_USER})"
    echo "  -h, --help            Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -p 12345 -c 8"
    echo "  $0 --udp --size 1024 --time 60"
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--port)
                PORT="$2"
                shift 2
                ;;
            -c|--core)
                CPU_CORE="$2"
                shift 2
                ;;
            -s|--size)
                MSG_SIZE="$2"
                shift 2
                ;;
            -t|--time)
                TEST_TIME="$2"
                shift 2
                ;;
            -u|--udp)
                PROTOCOL="udp"
                shift
                ;;
            --tcp)
                PROTOCOL="tcp"
                shift
                ;;
            -i|--ip)
                SERVER_IP="$2"
                shift 2
                ;;
            --user)
                SERVER_USER="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done
}

cleanup() {
    echo "Cleaning up remote server..."
    ssh -o ConnectTimeout=5 ${SERVER_USER}@${SERVER_IP} "sudo pkill -f 'sockperf server'" 2>/dev/null || true
    exit 0
}

check_prerequisites() {
    if ! command -v sockperf &> /dev/null; then
        echo "Error: sockperf not found on client. Please install sockperf first."
        exit 1
    fi

    if ! ping -c 1 ${SERVER_IP} &> /dev/null; then
        echo "Error: Cannot reach server at ${SERVER_IP}"
        exit 1
    fi

    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes ${SERVER_USER}@${SERVER_IP} exit 2>/dev/null; then
        echo "Error: Cannot SSH to ${SERVER_USER}@${SERVER_IP}"
        echo "Make sure SSH keys are set up for passwordless access"
        exit 1
    fi

    if ! ssh ${SERVER_USER}@${SERVER_IP} "command -v sockperf" &>/dev/null; then
        echo "Error: sockperf not found on server ${SERVER_IP}"
        echo "Please install sockperf on the server"
        exit 1
    fi
}

start_remote_server() {
    echo "Starting sockperf server on ${SERVER_IP}:${PORT} using CPU core ${CPU_CORE} (${PROTOCOL})"

    local protocol_flag=""
    if [[ "${PROTOCOL}" == "udp" ]]; then
        protocol_flag=""
    else
        protocol_flag="--tcp"
    fi

    ssh ${SERVER_USER}@${SERVER_IP} "sudo pkill -f 'sockperf server' 2>/dev/null || true"

    ssh ${SERVER_USER}@${SERVER_IP} "sudo taskset -c ${CPU_CORE} sockperf server ${protocol_flag} -p ${PORT}" &
    SERVER_PID=$!

    sleep 2

    # Only check TCP ports - UDP port checking with nc is unreliable
    if [[ "${PROTOCOL}" == "tcp" ]]; then
        if ! nc -z ${SERVER_IP} ${PORT} 2>/dev/null; then
            echo "Error: Server failed to start on ${SERVER_IP}:${PORT}"
            cleanup
            exit 1
        fi
    else
        # For UDP, just give the server more time to start
        sleep 3
    fi

    echo "Server started successfully"
}

run_client_test() {
    echo "Running sockperf ping-pong test against ${SERVER_IP}:${PORT}"
    echo "Parameters: protocol=${PROTOCOL}, msg-size=${MSG_SIZE}, time=${TEST_TIME}s, CPU core=${CPU_CORE}"

    local protocol_flag=""
    if [[ "${PROTOCOL}" == "udp" ]]; then
        protocol_flag=""
    else
        protocol_flag="--tcp"
    fi

    echo "Starting ping-pong test..."
    sudo taskset -c ${CPU_CORE} sockperf ping-pong ${protocol_flag} \
        -i ${SERVER_IP} -p ${PORT} \
        --msg-size ${MSG_SIZE} \
        --time ${TEST_TIME} \
        --full-rtt

    echo "Test completed!"
}

main() {
    parse_args "$@"

    trap cleanup SIGINT SIGTERM EXIT

    echo "=== Sockperf Ping-Pong Test ==="
    echo "Server: ${SERVER_USER}@${SERVER_IP}:${PORT}"
    echo "Protocol: ${PROTOCOL}"
    echo "Message size: ${MSG_SIZE} bytes"
    echo "Test duration: ${TEST_TIME} seconds"
    echo "CPU core: ${CPU_CORE}"
    echo ""

    check_prerequisites
    start_remote_server
    run_client_test
    cleanup
}

main "$@"
