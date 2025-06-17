#!/usr/bin/env bash
ip addr | grep "inet 10\.10\." | awk '{print $NF}' || exit 1