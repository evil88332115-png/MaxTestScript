#!/usr/bin/env bash
set -e

git clone https://github.com/eembc/coremark-pro.git
cd coremark-pro/
make TARGET=linux64 XCMD='-c6' certify-all
